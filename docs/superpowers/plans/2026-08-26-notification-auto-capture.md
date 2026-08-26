# Notification Auto-Capture (Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically capture card/bank payment transactions on Android by reading system notifications (not SMS), auto-saving a best-effort parsed transaction, and letting the user review/correct it afterward in the transaction list.

**Architecture:** Uses Android's `NotificationListenerService` (a special access the user grants once via system settings — NOT the Play-Store-restricted `READ_SMS` permission) to observe notifications from known bank/card/Samsung Pay apps. A pure-Dart parser (no Android dependency, fully unit-testable) extracts amount/merchant from the notification text. Successfully parsed notifications are saved immediately as a transaction tagged `source = 'notification_auto'` — no confirmation dialog — and reviewed/corrected later via a new transaction detail/edit screen. Unparseable notifications are silently skipped (the user can always add the transaction manually).

**Tech Stack:** Flutter/Android, Supabase/Postgres (existing `transactions` table, widened). A new Android-notification-listening package is chosen and verified during Task 6 (see that task for why the exact package isn't pinned in this plan).

**Spec:** [docs/superpowers/specs/2026-08-25-ppyu-gagyebu-design.md](../specs/2026-08-25-ppyu-gagyebu-design.md)

## Global Constraints

- Platform: Android only (unchanged).
- **No `READ_SMS`/`RECEIVE_SMS` permission anywhere in this feature.** Google Play restricts those to default SMS-handler apps; a budget app that requests them risks store rejection. Use `NotificationListenerService` instead — a special-access toggle, not a Play-restricted permission.
- Auto-captured transactions save immediately with no confirmation step; the user reviews/corrects via the transaction list → detail screen, not a popup at capture time (this was an explicit product decision — a prior confirmation-dialog design was rejected as buggy/disappearing).
- The original notification text/title is never sent to the server or stored server-side — only the parsed amount/merchant/timestamp (same "don't ship raw source text" rule Phase 1's spec set for SMS, now applied to notifications).
- Money stays `integer` (KRW, whole won) — unchanged from Phase 2.
- Repository tests that touch Supabase must use the real-`SupabaseClient`-against-local-`HttpServer` pattern established in Phase 2 (`ppyu_budget/test/features/ledger/*_repository_test.dart`) — never mocktail on `.from()`.
- Anything genuinely requiring a real Android device/OS (granting notification access, receiving a real system notification) cannot be automated in this environment (no Docker, no attached device) — those steps are manual-verification checklist items, not automated tests. Everything else (parsing logic, repository methods, screens with injectable repositories) must have real automated tests.

---

### Task 1: DB migration — `source` and `merchant` columns on `transactions`

**Files:**
- Create: `ppyu_budget/supabase/migrations/0004_transaction_source_merchant.sql`
- Create: `ppyu_budget/supabase/tests/0004_transaction_source_merchant_test.sql`

**Interfaces:**
- Produces: `transactions.source` (`text not null default 'manual' check (source in ('manual','notification_auto'))`), `transactions.merchant` (`text`, nullable) — Task 2's repository and model depend on these column names exactly.

- [ ] **Step 1: Write the migration**

`ppyu_budget/supabase/migrations/0004_transaction_source_merchant.sql`:
```sql
alter table transactions
  add column source text not null default 'manual' check (source in ('manual', 'notification_auto')),
  add column merchant text;
```

- [ ] **Step 2: Push the migration to the linked remote project**

Run (from `ppyu_budget/`): `npx -y supabase db push`

- [ ] **Step 3: Write the SQL test**

`ppyu_budget/supabase/tests/0004_transaction_source_merchant_test.sql`:
```sql
-- Run with: supabase db query --linked --file supabase/tests/0004_transaction_source_merchant_test.sql
begin;
set local role authenticated;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;

savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_source text;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  -- default source is 'manual' when omitted
  insert into transactions (household_id, account_id, category_id, member_id, type, amount)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 5000);

  select source into v_source from transactions where household_id = v_household_id;
  if v_source != 'manual' then
    raise exception 'TEST FAILED: expected default source manual, got %', v_source;
  end if;
end $$;
rollback to savepoint sp1;

-- an invalid source value is rejected
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
    values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 5000, 'bogus');
  exception when check_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: an invalid source value was accepted';
  end if;
end $$;
rollback to savepoint sp2;

rollback;
```

- [ ] **Step 4: Run the test**

Run: `npx -y supabase db query --linked --file supabase/tests/0004_transaction_source_merchant_test.sql`
Expected: no `TEST FAILED`, no unhandled error.

- [ ] **Step 5: Commit**

```bash
git add ppyu_budget/supabase/migrations/0004_transaction_source_merchant.sql ppyu_budget/supabase/tests/0004_transaction_source_merchant_test.sql
git commit -m "feat: add source and merchant columns to transactions"
```

---

### Task 2: Transaction model/repository — `merchant`/`source` fields, `update()`

**Files:**
- Modify: `ppyu_budget/lib/features/ledger/models/transaction.dart`
- Modify: `ppyu_budget/lib/features/ledger/transaction_repository.dart`
- Modify: `ppyu_budget/test/features/ledger/transaction_repository_test.dart`

**Interfaces:**
- Consumes: existing `LedgerTransaction`/`TransactionRepository` from Phase 2.
- Produces: `LedgerTransaction.merchant` (`String?`), `LedgerTransaction.source` (`String`); `TransactionRepository.create(...)` gains optional `merchant` (`String?`) and `source` (`String`, default `'manual'`) params; new `TransactionRepository.update({required String id, required String accountId, required String categoryId, required String type, required int amount, String? memo, String? merchant})` — Task 4/5's screens depend on this exact signature.

- [ ] **Step 1: Update the model**

`ppyu_budget/lib/features/ledger/models/transaction.dart` — replace the whole file:
```dart
class LedgerTransaction {
  const LedgerTransaction({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.memberId,
    required this.type,
    required this.amount,
    required this.occurredAt,
    required this.source,
    this.memo,
    this.merchant,
  });

  final String id;
  final String accountId;
  final String categoryId;
  final String memberId;
  final String type;
  final int amount;
  final DateTime occurredAt;
  final String source;
  final String? memo;
  final String? merchant;

  factory LedgerTransaction.fromJson(Map<String, dynamic> json) => LedgerTransaction(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        categoryId: json['category_id'] as String,
        memberId: json['member_id'] as String,
        type: json['type'] as String,
        amount: json['amount'] as int,
        occurredAt: DateTime.parse(json['occurred_at'] as String),
        source: json['source'] as String,
        memo: json['memo'] as String?,
        merchant: json['merchant'] as String?,
      );
}
```

- [ ] **Step 2: Write the failing tests for `create()`'s new params and `update()`**

Add to `ppyu_budget/test/features/ledger/transaction_repository_test.dart` (keep the existing 3 tests, add these — you'll need to update the existing `create` test's mocked JSON response to include `source`/`merchant` fields too, since `LedgerTransaction.fromJson` now requires `source`):
```dart
  test('create sends merchant and source when provided', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'a1',
      categoryId: 'c1',
      memberId: 'm1',
      type: 'expense',
      amount: 5000,
      merchant: '스타벅스',
      source: 'notification_auto',
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'account_id': 'a1',
      'category_id': 'c1',
      'member_id': 'm1',
      'type': 'expense',
      'amount': 5000,
      'memo': null,
      'merchant': '스타벅스',
      'source': 'notification_auto',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't3',
          'account_id': 'a1',
          'category_id': 'c1',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 5000,
          'occurred_at': '2026-08-26T09:00:00+00:00',
          'source': 'notification_auto',
          'memo': null,
          'merchant': '스타벅스',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.merchant, '스타벅스');
    expect(result.source, 'notification_auto');
  });

  test('update patches an existing transaction', () async {
    final future = repo.update(
      id: 't1',
      accountId: 'a2',
      categoryId: 'c2',
      type: 'expense',
      amount: 7000,
      memo: '수정됨',
      merchant: '스타벅스 강남점',
    );

    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.t1');
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'account_id': 'a2',
      'category_id': 'c2',
      'type': 'expense',
      'amount': 7000,
      'memo': '수정됨',
      'merchant': '스타벅스 강남점',
    });
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't1',
          'account_id': 'a2',
          'category_id': 'c2',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 7000,
          'occurred_at': '2026-08-26T09:00:00+00:00',
          'source': 'manual',
          'memo': '수정됨',
          'merchant': '스타벅스 강남점',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.amount, 7000);
    expect(result.merchant, '스타벅스 강남점');
  });
```

Also update the pre-existing `list fetches a household's transactions` and `create posts a new transaction` tests' mocked JSON to include `'source': 'manual', 'merchant': null` in their response bodies (required now that `fromJson` reads `source`), and update the `create posts a new transaction` test's expected request body to include `'merchant': null, 'source': 'manual'` (the new defaults `create()` will send).

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/features/ledger/transaction_repository_test.dart`
Expected: FAIL — `merchant`/`source`/`update` don't exist yet, and the pre-existing tests fail `fromJson`'s new required `source` field.

- [ ] **Step 3: Implement the repository changes**

`ppyu_budget/lib/features/ledger/transaction_repository.dart` — replace the whole file:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';

class TransactionRepository {
  TransactionRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<LedgerTransaction>> list(String householdId) async {
    final rows = await _client
        .from('transactions')
        .select()
        .eq('household_id', householdId)
        .order('occurred_at', ascending: false);
    return rows.map(LedgerTransaction.fromJson).toList();
  }

  Future<LedgerTransaction> create({
    required String householdId,
    required String accountId,
    required String categoryId,
    required String memberId,
    required String type,
    required int amount,
    String? memo,
    String? merchant,
    String source = 'manual',
  }) async {
    final rows = await _client.from('transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'member_id': memberId,
      'type': type,
      'amount': amount,
      'memo': memo,
      'merchant': merchant,
      'source': source,
    }).select();
    return LedgerTransaction.fromJson(rows.first);
  }

  Future<LedgerTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String type,
    required int amount,
    String? memo,
    String? merchant,
  }) async {
    final rows = await _client
        .from('transactions')
        .update({
          'account_id': accountId,
          'category_id': categoryId,
          'type': type,
          'amount': amount,
          'memo': memo,
          'merchant': merchant,
        })
        .eq('id', id)
        .select();
    return LedgerTransaction.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('transactions').delete().eq('id', id);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/features/ledger/transaction_repository_test.dart`
Expected: PASS (5 tests: list, create, create-with-merchant-and-source, update, delete)

- [ ] **Step 5: Run the full suite**

Run: `flutter test` AND `flutter analyze`
Expected: PASS — this change touches a shared model, so confirm nothing else (transaction_list_screen.dart, transaction_form_screen.dart) broke. If `transaction_form_screen.dart`'s call to `transactionRepository.create(...)` doesn't compile because it's missing required params, it isn't — `merchant`/`source` are optional/defaulted — but double check.

- [ ] **Step 6: Commit**

```bash
git add ppyu_budget/lib/features/ledger/models/transaction.dart ppyu_budget/lib/features/ledger/transaction_repository.dart \
        ppyu_budget/test/features/ledger/transaction_repository_test.dart
git commit -m "feat: add merchant/source fields and update() to transaction repository"
```

---

### Task 3: Notification text parser (pure Dart, no Android dependency)

**Files:**
- Create: `ppyu_budget/lib/features/notification_capture/notification_parser.dart`
- Test: `ppyu_budget/test/features/notification_capture/notification_parser_test.dart`

**Interfaces:**
- Produces: `class ParsedNotification { amount, merchant, occurredAt, issuerName }`; `class NotificationParser { static bool isKnownSource(String packageName); static ParsedNotification? parse(String packageName, String text) }` — Task 7 depends on both.

This is the one part of the feature safe to fully TDD — no Android/plugin dependency at all, just string parsing.

- [ ] **Step 1: Write the failing tests**

`ppyu_budget/test/features/notification_capture/notification_parser_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/notification_capture/notification_parser.dart';

void main() {
  test('isKnownSource is true for a recognized package', () {
    expect(NotificationParser.isKnownSource('com.samsung.android.spay'), isTrue);
  });

  test('isKnownSource is false for an unrecognized package', () {
    expect(NotificationParser.isKnownSource('com.some.other.app'), isFalse);
  });

  test('parse returns null for an unrecognized package', () {
    final result = NotificationParser.parse('com.some.other.app', '12,000원 결제되었습니다');
    expect(result, isNull);
  });

  test('parse returns null when no amount pattern is found', () {
    final result = NotificationParser.parse('com.samsung.android.spay', '알림 내용에 금액이 없음');
    expect(result, isNull);
  });

  test('parse extracts the amount from a recognized package\'s notification', () {
    final result = NotificationParser.parse(
      'com.samsung.android.spay',
      '삼성페이 12,000원 승인 스타벅스 강남점',
    );
    expect(result, isNotNull);
    expect(result!.amount, 12000);
    expect(result.issuerName, '삼성페이');
  });

  test('parse strips common boilerplate words from the merchant text', () {
    final result = NotificationParser.parse(
      'com.samsung.android.spay',
      '5,000원 승인 스타벅스',
    );
    expect(result, isNotNull);
    expect(result!.merchant, contains('스타벅스'));
    expect(result.merchant, isNot(contains('승인')));
  });

  test('parse falls back to the issuer name when merchant text is empty after stripping', () {
    final result = NotificationParser.parse('com.samsung.android.spay', '1,000원 승인');
    expect(result, isNotNull);
    expect(result!.merchant, '삼성페이');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/features/notification_capture/notification_parser_test.dart`
Expected: FAIL — `NotificationParser` doesn't exist.

- [ ] **Step 3: Implement the parser**

`ppyu_budget/lib/features/notification_capture/notification_parser.dart`:
```dart
class ParsedNotification {
  const ParsedNotification({
    required this.amount,
    required this.merchant,
    required this.occurredAt,
    required this.issuerName,
  });

  final int amount;
  final String merchant;
  final DateTime occurredAt;
  final String issuerName;
}

class NotificationParser {
  // ponytail: small, hand-picked allowlist to start — extend as the user's
  // actual bank/card apps turn out to post notifications this feature
  // should react to. Find a package name via `adb shell dumpsys
  // notification` while the real notification is showing, or the app's
  // Play Store URL (id=... query param).
  static const _knownIssuers = <String, String>{
    'com.samsung.android.spay': '삼성페이',
    'viva.republica.toss': '토스',
    'com.kbcard.cxh.appcard': 'KB국민카드',
    'com.shinhancard.smartshinhan': '신한카드',
    'kr.co.samsungcard.mpocket': '삼성카드',
  };

  static bool isKnownSource(String packageName) => _knownIssuers.containsKey(packageName);

  // ponytail: naive heuristic, not a real NLP parser. Strips the matched
  // amount and a few common Korean payment-notification boilerplate words,
  // then uses whatever's left as the merchant name. Tune the boilerplate
  // list (or add per-issuer overrides keyed on packageName) once real
  // notification samples from the user's own bank/card apps are collected —
  // this is expected to need iteration, not a one-shot solution.
  static ParsedNotification? parse(String packageName, String text) {
    final issuerName = _knownIssuers[packageName];
    if (issuerName == null) return null;

    final amountMatch = RegExp(r'([\d,]+)\s*원').firstMatch(text);
    if (amountMatch == null) return null;
    final amount = int.parse(amountMatch.group(1)!.replaceAll(',', ''));

    var merchant = text
        .replaceAll(amountMatch.group(0)!, '')
        .replaceAll(RegExp(r'(승인|결제|사용|일시불|누적|완료)'), '')
        .trim();
    if (merchant.isEmpty) merchant = issuerName;

    return ParsedNotification(
      amount: amount,
      merchant: merchant,
      occurredAt: DateTime.now(),
      issuerName: issuerName,
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/features/notification_capture/notification_parser_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 5: Run the full suite**

Run: `flutter test` AND `flutter analyze`

- [ ] **Step 6: Commit**

```bash
git add ppyu_budget/lib/features/notification_capture/notification_parser.dart \
        ppyu_budget/test/features/notification_capture/notification_parser_test.dart
git commit -m "feat: add notification text parser for known bank/card/Samsung Pay sources"
```

---

### Task 4: Transaction list screen — show date/amount/merchant, tap to open detail

**Files:**
- Modify: `ppyu_budget/lib/features/ledger/transaction_list_screen.dart`
- Create: `ppyu_budget/lib/features/ledger/transaction_detail_screen.dart` (placeholder shell — full implementation is Task 5; this task just needs it to exist so the list can navigate to it)

**Interfaces:**
- Consumes: `LedgerTransaction` (Task 2, with `merchant`/`source`).
- Produces: `TransactionDetailScreen` constructor shape `TransactionDetailScreen({required String householdId, required LedgerTransaction transaction})` — Task 5 fills in the body; this task only needs the constructor to exist and compile.

- [ ] **Step 1: Create the placeholder detail screen**

`ppyu_budget/lib/features/ledger/transaction_detail_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';

class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({
    super.key,
    required this.householdId,
    required this.transaction,
  });

  final String householdId;
  final LedgerTransaction transaction;

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('거래 상세')),
      body: Center(child: Text('${widget.transaction.amount}원')),
    );
  }
}
```
(Task 5 replaces this file's body with the real edit form — this step just makes it exist and compile so Task 4's navigation has something to push.)

- [ ] **Step 2: Update the list screen**

`ppyu_budget/lib/features/ledger/transaction_list_screen.dart` — replace the whole file:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_detail_screen.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart';

class TransactionListScreen extends StatefulWidget {
  const TransactionListScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {
  List<LedgerTransaction>? _transactions;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final transactions = await transactionRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _transactions = transactions;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 내역을 불러오지 못했어요');
    }
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$mm/$dd $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final transactions = _transactions;
    return Scaffold(
      appBar: AppBar(title: const Text('거래 내역')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TransactionFormScreen(householdId: widget.householdId),
          ));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: transactions == null
                ? const Center(child: CircularProgressIndicator())
                : transactions.isEmpty
                    ? const Center(child: Text('아직 거래 내역이 없어요'))
                    : ListView.builder(
                        itemCount: transactions.length,
                        itemBuilder: (context, i) {
                          final t = transactions[i];
                          final sign = t.type == 'expense' ? '-' : '+';
                          return ListTile(
                            leading: t.source == 'notification_auto'
                                ? const Icon(Icons.notifications_active, size: 20)
                                : null,
                            title: Text(t.merchant?.isNotEmpty == true ? t.merchant! : (t.memo ?? '(내용 없음)')),
                            subtitle: Text(_formatDate(t.occurredAt)),
                            trailing: Text('$sign${t.amount}원'),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => TransactionDetailScreen(
                                  householdId: widget.householdId,
                                  transaction: t,
                                ),
                              ));
                              _load();
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Run the full test suite**

Run: `flutter test` AND `flutter analyze`
Expected: PASS, no new analyze errors.

- [ ] **Step 4: Commit**

```bash
git add ppyu_budget/lib/features/ledger/transaction_list_screen.dart ppyu_budget/lib/features/ledger/transaction_detail_screen.dart
git commit -m "feat: show date/merchant in transaction list, navigate to detail on tap"
```

---

### Task 5: Transaction detail/edit screen (real implementation)

**Files:**
- Modify: `ppyu_budget/lib/features/ledger/transaction_detail_screen.dart` (replaces Task 4's placeholder body)

**Interfaces:**
- Consumes: `TransactionRepository.update(...)` (Task 2), `AccountRepository`/`CategoryRepository` (Phase 2, via `account_screen.dart show accountRepository` / `category_screen.dart show categoryRepository`).
- Produces: nothing consumed elsewhere — this is a leaf screen.

- [ ] **Step 1: Replace the placeholder with the real edit form**

`ppyu_budget/lib/features/ledger/transaction_detail_screen.dart` — replace the whole file:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/models/account.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;

class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({
    super.key,
    required this.householdId,
    required this.transaction,
  });

  final String householdId;
  final LedgerTransaction transaction;

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  late final _amountController =
      TextEditingController(text: widget.transaction.amount.toString());
  late final _memoController = TextEditingController(text: widget.transaction.memo ?? '');
  late final _merchantController =
      TextEditingController(text: widget.transaction.merchant ?? '');
  late String _type = widget.transaction.type;
  late String? _accountId = widget.transaction.accountId;
  late String? _categoryId = widget.transaction.categoryId;
  List<Account>? _accounts;
  List<Category>? _categories;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      final accounts = await accountRepository.list(widget.householdId);
      final categories = await categoryRepository.list(widget.householdId, type: _type);
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _categories = categories;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '옵션을 불러오지 못했어요');
    }
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amountController.text.trim());
    final accountId = _accountId;
    final categoryId = _categoryId;
    if (amount == null || amount <= 0 || accountId == null || categoryId == null) {
      setState(() => _error = '금액, 계좌, 카테고리를 확인해주세요');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await transactionRepository.update(
        id: widget.transaction.id,
        accountId: accountId,
        categoryId: categoryId,
        type: _type,
        amount: amount,
        memo: _memoController.text.trim().isEmpty ? null : _memoController.text.trim(),
        merchant: _merchantController.text.trim().isEmpty ? null : _merchantController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 수정에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _memoController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final categories = _categories;
    if (accounts == null || categories == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('거래 상세')),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
            : const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('거래 상세')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (widget.transaction.source == 'notification_auto')
              const Text('알림에서 자동으로 채워졌어요. 틀린 부분이 있으면 고쳐주세요.',
                  style: TextStyle(color: Colors.grey)),
            DropdownButton<String>(
              value: _type,
              items: const [
                DropdownMenuItem(value: 'expense', child: Text('지출')),
                DropdownMenuItem(value: 'income', child: Text('수입')),
              ],
              onChanged: (v) {
                setState(() => _type = v ?? 'expense');
                _loadOptions();
              },
            ),
            TextField(
              controller: _amountController,
              decoration: const InputDecoration(labelText: '금액'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: _merchantController,
              decoration: const InputDecoration(labelText: '사용처'),
            ),
            if (accounts.isNotEmpty)
              DropdownButton<String>(
                value: accounts.any((a) => a.id == _accountId) ? _accountId : accounts.first.id,
                items: accounts
                    .map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
                    .toList(),
                onChanged: (v) => setState(() => _accountId = v),
              ),
            if (categories.isNotEmpty)
              DropdownButton<String>(
                value: categories.any((c) => c.id == _categoryId) ? _categoryId : categories.first.id,
                items: categories
                    .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
                    .toList(),
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            TextField(
              controller: _memoController,
              decoration: const InputDecoration(labelText: '메모(선택)'),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run the full test suite**

Run: `flutter test` AND `flutter analyze`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add ppyu_budget/lib/features/ledger/transaction_detail_screen.dart
git commit -m "feat: implement transaction detail/edit screen"
```

---

### Task 6: Android notification-listener plugin integration

**Files:**
- Modify: `ppyu_budget/pubspec.yaml`
- Modify: `ppyu_budget/android/app/src/main/AndroidManifest.xml`
- Create: `ppyu_budget/lib/features/notification_capture/notification_capture_service.dart`

**Interfaces:**
- Produces: `class RawNotification { final String packageName; final String text; }`; `class NotificationCaptureService { Future<bool> isAccessGranted(); Future<void> openAccessSettings(); Stream<RawNotification> get notifications; }` — Task 7 depends on this exact shape.

**This task requires research you must do yourself — do not guess.** No specific Android-notification-listener Flutter package is pinned in this plan because the package landscape changes and the last one checked may be unmaintained by the time you read this. Before writing any code:

1. Search pub.dev (or the web) for a currently-maintained Flutter plugin implementing Android's `NotificationListenerService` (search terms like "flutter notification listener android"). Prioritize: still-maintained (recent updates), reasonable pub.dev score, and — critically — an API that gives you (a) a way to check/request "notification access" (the special settings toggle, distinct from a runtime permission) and (b) a stream or callback of incoming notifications with at least the source app's package name and the notification text.
2. Read that package's actual installed source/docs once added to `pubspec.yaml` (same practice used throughout this project — never assume an API surface, verify it against the real installed package, the same way earlier phases caught real API mismatches this way).
3. Wrap whatever that package's real API looks like behind the `NotificationCaptureService` interface specified above, so the rest of this plan (Task 7) never needs to know which underlying package you picked.

**Do not implement `READ_SMS`/`RECEIVE_SMS` or any SMS-reading permission anywhere — this task is notification-listener only,** per this plan's Global Constraints.

- [ ] **Step 1: Add the chosen package**

Run: `flutter pub add <package_name>` (from `ppyu_budget/`) — whichever package you selected in your research above.

- [ ] **Step 2: Add the Android manifest entries the package's own docs specify**

Edit `ppyu_budget/android/app/src/main/AndroidManifest.xml` to add whatever `<service>` declaration (typically requiring `android.permission.BIND_NOTIFICATION_LISTENER_SERVICE` and an intent-filter for `android.service.notification.NotificationListenerService`) and/or permissions the package's setup instructions require. Follow the package's docs exactly for this step — manifest requirements are plugin-specific and must match what you actually installed.

- [ ] **Step 3: Implement the wrapper service**

`ppyu_budget/lib/features/notification_capture/notification_capture_service.dart` — implement against the real API you verified in your research, conforming to this interface:
```dart
class RawNotification {
  const RawNotification({required this.packageName, required this.text});

  final String packageName;
  final String text;
}

class NotificationCaptureService {
  // Returns whether the user has already granted notification access.
  Future<bool> isAccessGranted() async {
    // TODO: call whatever the chosen package exposes for checking this.
    throw UnimplementedError();
  }

  // Opens the system settings screen where the user grants notification
  // access (Android's Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS, or
  // whatever the chosen package wraps it as).
  Future<void> openAccessSettings() async {
    throw UnimplementedError();
  }

  // A stream of every notification the listener observes system-wide.
  // Callers (Task 7) are responsible for filtering to known sources —
  // this service doesn't know about banks/cards/Samsung Pay.
  Stream<RawNotification> get notifications {
    throw UnimplementedError();
  }
}
```
Replace the three `throw UnimplementedError()` bodies with real implementations backed by the package you chose. If the package's stream type carries more fields (title, timestamp, etc.) than `RawNotification` needs, map only `packageName` and `text` (concatenate title+text if the package splits them, since `NotificationParser.parse` from Task 3 takes a single `text` string).

- [ ] **Step 4: Manual verification (no automated test possible here — this needs a real device/OS)**

This plumbing cannot be exercised by `flutter test` (it needs the real Android notification subsystem). Verify manually once a device is available:
1. Run the app on a real Android device or emulator with Google Play services (notification listener behavior is unreliable on bare AOSP emulators).
2. Call `isAccessGranted()` — confirm it returns `false` before the user has granted access.
3. Call `openAccessSettings()` — confirm it opens the correct system settings screen.
4. Grant access manually in that settings screen, return to the app, confirm `isAccessGranted()` now returns `true`.
5. Trigger a test notification from any app (e.g. send yourself a message in any messaging app) and confirm `notifications` emits a `RawNotification` with the correct `packageName`.

Record the outcome of this manual check in your report — if a device isn't available in this environment, say so explicitly and mark this step as deferred to the user, the same way earlier phases deferred device-dependent manual checks.

- [ ] **Step 5: Run the automated test suite (confirms nothing else broke)**

Run: `flutter test` AND `flutter analyze`
Expected: PASS — this task adds no automated tests of its own (see Step 4), but must not break existing ones.

- [ ] **Step 6: Commit**

```bash
git add ppyu_budget/pubspec.yaml ppyu_budget/pubspec.lock ppyu_budget/android/app/src/main/AndroidManifest.xml \
        ppyu_budget/lib/features/notification_capture/notification_capture_service.dart
git commit -m "feat: integrate Android notification listener plugin"
```

---

### Task 7: Auto-save wiring — notification → parsed transaction

**Files:**
- Create: `ppyu_budget/lib/features/notification_capture/notification_auto_save_service.dart`
- Test: `ppyu_budget/test/features/notification_capture/notification_auto_save_service_test.dart`

**Interfaces:**
- Consumes: `NotificationCaptureService.notifications` (Task 6, `Stream<RawNotification>`), `NotificationParser` (Task 3), `AccountRepository`/`CategoryRepository`/`TransactionRepository` (Phase 2 + Task 2), `supabase` getter.
- Produces: `class NotificationAutoSaveService { NotificationAutoSaveService({required Stream<RawNotification> notifications, required String householdId, required AccountRepository accountRepository, required CategoryRepository categoryRepository, required TransactionRepository transactionRepository}); void start(); void stop(); }` — Task 8 wires this into the app.

This is fully unit-testable: inject a fake `Stream<RawNotification>` (a `StreamController` you control in the test) and fake repositories, so no real Android plugin or network call is needed.

- [ ] **Step 1: Write the failing test**

`ppyu_budget/test/features/notification_capture/notification_auto_save_service_test.dart`:
```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/account_repository.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';
import 'package:ppyu_budget/features/notification_capture/notification_auto_save_service.dart';
import 'package:ppyu_budget/features/notification_capture/notification_capture_service.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late StreamController<RawNotification> notificationController;
  late NotificationAutoSaveService service;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    notificationController = StreamController<RawNotification>();
    service = NotificationAutoSaveService(
      notifications: notificationController.stream,
      householdId: 'household-1',
      memberId: 'member-1',
      accountRepository: AccountRepository(client: client),
      categoryRepository: CategoryRepository(client: client),
      transactionRepository: TransactionRepository(client: client),
    );
  });

  tearDown(() async {
    service.stop();
    await notificationController.close();
    await client.dispose();
    await mockServer.close(force: true);
  });

  Future<HttpRequest> respondJson(List<Map<String, Object?>> body, {int status = 200}) async {
    final request = await mockServer.first;
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
    return request;
  }

  test('parses a known-source notification, finds-or-creates the account, and saves a transaction',
      () async {
    service.start();
    notificationController.add(const RawNotification(
      packageName: 'com.samsung.android.spay',
      text: '5,000원 승인 스타벅스',
    ));

    // 1: account lookup — no existing "삼성페이" account
    final accountLookup = await respondJson([]);
    expect(accountLookup.uri.path, endsWith('/accounts'));

    // 2: account creation
    final accountCreate = await respondJson([
      {'id': 'acc-1', 'name': '삼성페이', 'type': 'card'}
    ], status: 201);
    expect(accountCreate.method, 'POST');

    // 3: category lookup — pick the default "기타" expense category
    final categoryLookup = await respondJson([
      {'id': 'cat-1', 'name': '기타', 'type': 'expense', 'icon': null, 'is_default': true}
    ]);
    expect(categoryLookup.uri.path, endsWith('/categories'));

    // 4: transaction insert
    final txnInsert = await respondJson([
      {
        'id': 't1',
        'account_id': 'acc-1',
        'category_id': 'cat-1',
        'member_id': 'member-1',
        'type': 'expense',
        'amount': 5000,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'source': 'notification_auto',
        'memo': null,
        'merchant': '스타벅스',
      }
    ], status: 201);
    expect(txnInsert.uri.path, endsWith('/transactions'));
    final bodyStr = await utf8.decodeStream(txnInsert);
    final body = jsonDecode(bodyStr) as Map<String, dynamic>;
    expect(body['amount'], 5000);
    expect(body['source'], 'notification_auto');
    expect(body['merchant'], '스타벅스');
  });

  test('ignores a notification from an unrecognized source', () async {
    service.start();
    notificationController.add(const RawNotification(
      packageName: 'com.some.other.app',
      text: '5,000원 승인 어딘가',
    ));

    // give the stream a moment to process, then confirm no request was made
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mockServer.first.timeout(const Duration(milliseconds: 50)), throwsA(anything));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/notification_capture/notification_auto_save_service_test.dart`
Expected: FAIL — `NotificationAutoSaveService` doesn't exist.

- [ ] **Step 3: Implement the service**

`ppyu_budget/lib/features/notification_capture/notification_auto_save_service.dart`:
```dart
import 'dart:async';

import 'package:ppyu_budget/features/ledger/account_repository.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';
import 'package:ppyu_budget/features/notification_capture/notification_capture_service.dart';
import 'package:ppyu_budget/features/notification_capture/notification_parser.dart';

class NotificationAutoSaveService {
  NotificationAutoSaveService({
    required Stream<RawNotification> notifications,
    required this.householdId,
    required this.memberId,
    required this.accountRepository,
    required this.categoryRepository,
    required this.transactionRepository,
  }) : _notifications = notifications;

  final Stream<RawNotification> _notifications;
  final String householdId;
  final String memberId;
  final AccountRepository accountRepository;
  final CategoryRepository categoryRepository;
  final TransactionRepository transactionRepository;

  StreamSubscription<RawNotification>? _subscription;

  void start() {
    _subscription = _notifications.listen(_handle);
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _handle(RawNotification notification) async {
    final parsed = NotificationParser.parse(notification.packageName, notification.text);
    if (parsed == null) return;

    final accounts = await accountRepository.list(householdId);
    final existing = accounts.where((a) => a.name == parsed.issuerName);
    final accountId = existing.isNotEmpty
        ? existing.first.id
        : (await accountRepository.create(householdId, parsed.issuerName, 'card')).id;

    final categories = await categoryRepository.list(householdId, type: 'expense');
    final fallbackCategory = categories.where((c) => c.name == '기타');
    final categoryId = fallbackCategory.isNotEmpty
        ? fallbackCategory.first.id
        : (categories.isNotEmpty ? categories.first.id : null);
    if (categoryId == null) return;

    await transactionRepository.create(
      householdId: householdId,
      accountId: accountId,
      categoryId: categoryId,
      memberId: memberId,
      type: 'expense',
      amount: parsed.amount,
      merchant: parsed.merchant,
      source: 'notification_auto',
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/notification_capture/notification_auto_save_service_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Run the full suite**

Run: `flutter test` AND `flutter analyze`

- [ ] **Step 6: Commit**

```bash
git add ppyu_budget/lib/features/notification_capture/notification_auto_save_service.dart \
        ppyu_budget/test/features/notification_capture/notification_auto_save_service_test.dart
git commit -m "feat: wire notification parsing into auto-saved transactions"
```

---

### Task 8: Onboarding screen + wire into the app

**Files:**
- Create: `ppyu_budget/lib/features/notification_capture/notification_onboarding_screen.dart`
- Modify: `ppyu_budget/lib/features/household/home_screen.dart`

**Interfaces:**
- Consumes: `NotificationCaptureService` (Task 6), `NotificationAutoSaveService` (Task 7).
- Produces: nothing consumed elsewhere — final integration point for this plan.

- [ ] **Step 1: Build the onboarding screen**

`ppyu_budget/lib/features/notification_capture/notification_onboarding_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/notification_capture/notification_capture_service.dart';

final notificationCaptureService = NotificationCaptureService();

class NotificationOnboardingScreen extends StatefulWidget {
  const NotificationOnboardingScreen({super.key});

  @override
  State<NotificationOnboardingScreen> createState() => _NotificationOnboardingScreenState();
}

class _NotificationOnboardingScreenState extends State<NotificationOnboardingScreen>
    with WidgetsBindingObserver {
  bool? _granted;
  // Task 6's NotificationCaptureService documents that openAccessSettings()
  // and isAccessGranted() must never overlap in time (the native side shares
  // one result callback across all plugin methods, so calling isAccessGranted()
  // while openAccessSettings() is still pending can make openAccessSettings()
  // hang forever). This guard stops the lifecycle-resume auto-refresh below
  // from racing a still-in-flight openAccessSettings() call.
  bool _openingSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // catches the user coming back from the system settings screen
    if (state == AppLifecycleState.resumed && !_openingSettings) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await notificationCaptureService.isAccessGranted();
    if (!mounted) return;
    setState(() => _granted = granted);
  }

  Future<void> _openSettings() async {
    setState(() => _openingSettings = true);
    await notificationCaptureService.openAccessSettings();
    _openingSettings = false;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('결제 알림 자동인식')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '카드/은행 결제 알림이 뜰 때 자동으로 거래를 기록해줘요.\n'
              'SMS가 아니라 "알림"을 읽는 방식이라 문자 읽기 권한은 필요 없어요.',
            ),
            const SizedBox(height: 16),
            Text(
              _granted == null
                  ? '상태 확인 중...'
                  : _granted!
                      ? '✅ 알림 접근이 허용되어 있어요.'
                      : '❌ 아직 알림 접근이 허용되지 않았어요.',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _openingSettings ? null : _openSettings,
              child: const Text('알림 접근 설정 열기'),
            ),
            const SizedBox(height: 24),
            const Text(
              '⚠️ 꼭 확인해주세요',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text(
              '위 설정을 켜도, 사용하시는 은행/카드 앱 자체의 알림이 꺼져있으면 자동인식이 안 돼요.\n'
              '휴대폰 설정 > 앱 > (은행/카드 앱 이름) > 알림에서 결제 알림을 켜주세요.\n'
              '삼성페이를 쓰신다면 삼성페이 알림도 켜주셔야 인식돼요.',
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Add a menu entry in `home_screen.dart`**

Add one more `ListTile` to the has-household branch's `ListView` (alongside the existing 배우자 초대/거래 내역/계좌/카테고리/예산/저축목표 items):
```dart
            ListTile(
              title: const Text('결제 알림 자동인식 설정'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NotificationOnboardingScreen(),
              )),
            ),
```
Add the corresponding import:
```dart
import 'package:ppyu_budget/features/notification_capture/notification_onboarding_screen.dart';
```

- [ ] **Step 3: Run the full test suite**

Run: `flutter test` AND `flutter analyze`
Expected: PASS, no new analyze errors.

- [ ] **Step 4: Manual smoke check (requires a real device — same caveat as Task 6, defer to the user if unavailable)**

If a device is available: log in, open "결제 알림 자동인식 설정" from the home menu, tap "알림 접근 설정 열기", grant access in system settings, return to the app, confirm the status flips to "✅ 알림 접근이 허용되어 있어요." Then send yourself a test message from a recognized app (e.g. install a throwaway app with one of the allowlisted package names, or temporarily add your actual messaging app's package to `NotificationParser`'s allowlist for testing) and confirm a transaction appears in the transaction list tagged with the notification icon.

Note starting `NotificationAutoSaveService.start()` at app launch (wiring it into `main.dart` so it runs whenever a household exists) is intentionally NOT part of this task — that's real iteration work once the user has tested Task 6/7's plumbing against their own phone's real bank apps and tuned `NotificationParser`'s allowlist/regex accordingly, per the "build it and iterate while using it" approach agreed for this phase. Note this explicitly in your report so it isn't mistaken for an oversight.

- [ ] **Step 5: Commit**

```bash
git add ppyu_budget/lib/features/notification_capture/notification_onboarding_screen.dart ppyu_budget/lib/features/household/home_screen.dart
git commit -m "feat: add notification auto-capture onboarding screen and home menu entry"
```
