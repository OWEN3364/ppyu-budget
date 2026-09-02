# 반복거래·자동인식 거래 "확인 후 등록" 재설계 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CAS-based recurring-transaction catch-up mechanism with a DB-unique-index-based "confirm or auto" model, add a 나/배우자 todo list for unconfirmed recurring occurrences, extend notification-capture with the same confirm/auto concept, and unify both under one new home-screen menu.

**Architecture:** A partial unique index on `transactions (recurring_transaction_id, occurred_at)` makes duplicate-occurrence creation structurally impossible, eliminating all CAS/pointer-advance code. "Pending" recurring occurrences become a computed diff (expected dates from a fixed `start_at`, minus dates that already have a matching transaction) shared by both the silent auto-catch-up path and the new todo-list UI. Notification-capture keeps its existing event-driven save path but gains a `confirmed` flag and a local setting that decides whether a captured notification starts out confirmed or pending.

**Tech Stack:** Flutter (Dart), Supabase (Postgres + PostgREST + RLS), `shared_preferences` (new dependency, per-device local settings).

**Spec:** [docs/superpowers/specs/2026-09-02-recurring-and-notification-todo-design.md](../specs/2026-09-02-recurring-and-notification-todo-design.md) — this plan implements sections 2–5 of that spec in full, superseding section 3 ("소급 생성 메커니즘") of the earlier [2026-08-27-recurring-transactions-design.md](../specs/2026-08-27-recurring-transactions-design.md).

## Global Constraints

- SQL is tested via `supabase db query --linked --file <path>` wrapped in `begin;`/`rollback;` with `savepoint`/`rollback to savepoint` per scenario, and `set local role authenticated;` once at file top level (never inside a `do $$` block).
- Every `timestamptz` column read into a Dart model must go through `DateTime.parse(...).toLocal()` — PostgREST returns UTC-suffixed strings.
- Occurrence identity is compared by instant, via `.toUtc()`, never by local calendar fields — an already-existing `occurred_at` value read back from PostgREST may or may not already be `.toLocal()`-converted depending on which model read it.
- `maxCatchUpOccurrences` (60, in `recurring_transaction_schedule.dart`) is reused unchanged as the cap on occurrences *examined* per call to the new `missingOccurrences` — this is a ponytail-flagged shared ceiling, not a new mechanism.
- A duplicate-occurrence insert is caught as `PostgrestException` with `e.code == '23505'` (verified against the pinned `postgrest` 2.9.1 source: `PostgrestException.code` carries the raw Postgres SQLSTATE forwarded in PostgREST's error body for a genuine DB constraint failure, not an HTTP status).
- The notification-capture confirm/auto setting is local-only (`shared_preferences`, per-device) — never synced through Supabase, since notifications only ever arrive on one spouse's phone.
- `owner_member_id` is a separate concept from `created_by`: who a transaction is attributed to vs. who created the template row.

---

### Task 1: Migration — owner/auto-register/confirm columns + occurrence uniqueness

**Files:**
- Create: `supabase/migrations/0011_recurring_transaction_todo.sql`
- Create: `supabase/tests/0011_recurring_transaction_todo_test.sql`

**Interfaces:**
- Produces: `recurring_transactions.owner_member_id` (uuid, not null, FK → `household_members.id`), `recurring_transactions.auto_register` (bool, not null, default false), `recurring_transactions.start_at` (renamed from `next_run_at`), `transactions.recurring_transaction_id` (uuid, nullable, FK → `recurring_transactions.id`), `transactions.confirmed` (bool, not null, default true), unique index `transactions_recurring_occurrence_unique`.

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/0011_recurring_transaction_todo.sql

-- owner_member_id: who the spending is attributed to (separate from
-- created_by, who authored the template row). Backfilled from created_by
-- since every existing template's owner is presumed to be its creator.
alter table recurring_transactions
  add column owner_member_id uuid references household_members(id) on delete restrict,
  add column auto_register boolean not null default false;

update recurring_transactions set owner_member_id = created_by where owner_member_id is null;

alter table recurring_transactions alter column owner_member_id set not null;

-- start_at is no longer a pointer the catch-up service advances — it's a
-- fixed calculation anchor. "Done" is now derived from whether a matching
-- transaction exists (see the unique index below), not from this column.
alter table recurring_transactions rename column next_run_at to start_at;

drop policy "members can insert recurring_transactions" on recurring_transactions;
create policy "members can insert recurring_transactions" on recurring_transactions for insert with check (
  is_household_member(household_id)
  and exists (select 1 from household_members m where m.id = created_by and m.household_id = recurring_transactions.household_id)
  and exists (select 1 from household_members m where m.id = owner_member_id and m.household_id = recurring_transactions.household_id)
);

-- recurring_transaction_id + occurred_at identifies one occurrence.
-- confirmed defaults true so every existing row (manual, recurring_auto,
-- and today's notification_auto rows) is unaffected.
alter table transactions
  add column recurring_transaction_id uuid references recurring_transactions(id) on delete set null,
  add column confirmed boolean not null default true;

-- The core of the redesign: this index makes a duplicate occurrence
-- insert fail at the database, structurally, regardless of how many
-- sessions race to create it — no CAS/advance-tracking needed anywhere in
-- application code. Partial (where clause) so ordinary manual transactions
-- (recurring_transaction_id is null) are never constrained by it.
create unique index transactions_recurring_occurrence_unique
  on transactions (recurring_transaction_id, occurred_at)
  where recurring_transaction_id is not null;
```

- [ ] **Step 2: Write the SQL test**

```sql
-- supabase/tests/0011_recurring_transaction_todo_test.sql
-- Run with: supabase db query --linked --file supabase/tests/0011_recurring_transaction_todo_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- insert policy rejects an owner_member_id from a DIFFERENT household
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_member_b uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select id into v_member_b from household_members where household_id = v_household_b and user_id = auth.uid();

  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
    values (v_household_a, v_account_a, v_category_a, v_member_a, v_member_b, 'expense', 50000, 'MONTHLY', now());
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: insert should have been rejected for an owner_member_id from a different household';
  end if;
end $$;
rollback to savepoint sp1;

-- insert policy still allows a legitimate same-household owner_member_id,
-- and start_at (the renamed column) round-trips correctly
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_a uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_template_id uuid;
  v_start_at timestamptz;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at, auto_register)
  values (v_household_id, v_account_id, v_category_id, v_member_a, v_member_a, 'expense', 50000, 'MONTHLY', '2026-09-01'::timestamptz, true)
  returning id, start_at into v_template_id, v_start_at;

  if v_template_id is null or v_start_at != '2026-09-01'::timestamptz then
    raise exception 'TEST FAILED: a legitimate insert with a same-household owner_member_id was rejected or start_at did not round-trip';
  end if;
end $$;
rollback to savepoint sp2;

-- the unique index blocks a second transaction for the same
-- (recurring_transaction_id, occurred_at) pair, but allows a different
-- occurred_at for the same template, and never constrains manual
-- transactions (recurring_transaction_id is null)
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_template_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, owner_member_id, type, amount, interval_rule, start_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, v_member_id, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_id;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at, recurring_transaction_id)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 50000, 'recurring_auto', '2026-09-01'::timestamptz, v_template_id);

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at, recurring_transaction_id)
    values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 50000, 'recurring_auto', '2026-09-01'::timestamptz, v_template_id);
  exception when unique_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a duplicate (recurring_transaction_id, occurred_at) pair was allowed';
  end if;

  -- a different occurred_at for the same template is fine
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at, recurring_transaction_id)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 50000, 'recurring_auto', '2026-10-01'::timestamptz, v_template_id);

  -- two manual transactions (recurring_transaction_id null) on the same
  -- occurred_at are never constrained by the partial index
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000, 'manual', '2026-09-01'::timestamptz);
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source, occurred_at)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000, 'manual', '2026-09-01'::timestamptz);
end $$;
rollback to savepoint sp3;

-- confirmed defaults to true for an ordinary insert that doesn't specify it
savepoint sp4;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
  v_confirmed boolean;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 1000, 'manual')
  returning confirmed into v_confirmed;

  if v_confirmed is not true then
    raise exception 'TEST FAILED: confirmed did not default to true';
  end if;
end $$;
rollback to savepoint sp4;

rollback;
```

- [ ] **Step 3: Apply and run the test**

Run:
```bash
npx --yes supabase db query --linked --file supabase/tests/0011_recurring_transaction_todo_test.sql
```
Expected: no `TEST FAILED` output. This applies the migration to the linked project as a side effect the first time `supabase db push` or the CLI's auto-apply runs it — if the test run reports the columns/index don't exist yet, run `npx --yes supabase db push` first, then re-run the test.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0011_recurring_transaction_todo.sql supabase/tests/0011_recurring_transaction_todo_test.sql
git commit -m "feat(db): owner/auto-register on recurring_transactions, confirmed + occurrence-unique on transactions"
```

---

### Task 2: RecurringTransaction model + repository rewrite

**Files:**
- Modify: `lib/features/ledger/models/recurring_transaction.dart`
- Modify: `lib/features/ledger/recurring_transaction_repository.dart`
- Modify: `test/features/ledger/recurring_transaction_repository_test.dart`

**Interfaces:**
- Consumes: `recurring_transactions.owner_member_id`/`auto_register`/`start_at` (Task 1).
- Produces: `RecurringTransaction.ownerMemberId` (String), `.startAt` (DateTime, renamed from `.nextRunAt`), `.autoRegister` (bool). `RecurringTransactionRepository.create({..., required String ownerMemberId, required DateTime startAt, bool autoRegister = false})`, `.update({..., required String ownerMemberId, required DateTime startAt, required bool autoRegister})` — `startAt` is now a plain required field, not optional/omittable (see rationale in the update's doc comment). `advanceNextRunAt` is deleted entirely.

- [ ] **Step 1: Rewrite the model**

```dart
// lib/features/ledger/models/recurring_transaction.dart
class RecurringTransaction {
  const RecurringTransaction({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.createdBy,
    required this.ownerMemberId,
    required this.type,
    required this.amount,
    required this.intervalRule,
    required this.startAt,
    required this.autoRegister,
    this.memo,
  });

  final String id;
  final String accountId;
  final String categoryId;
  final String createdBy;
  final String ownerMemberId;
  final String type;
  final int amount;
  final String intervalRule;
  final DateTime startAt;
  final bool autoRegister;
  final String? memo;

  factory RecurringTransaction.fromJson(Map<String, dynamic> json) => RecurringTransaction(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        categoryId: json['category_id'] as String,
        createdBy: json['created_by'] as String,
        ownerMemberId: json['owner_member_id'] as String,
        type: json['type'] as String,
        amount: json['amount'] as int,
        intervalRule: json['interval_rule'] as String,
        // See Global Constraints: PostgREST returns timestamptz with a UTC
        // suffix — .toLocal() keeps every downstream date calculation and
        // display consistent.
        startAt: DateTime.parse(json['start_at'] as String).toLocal(),
        autoRegister: json['auto_register'] as bool,
        memo: json['memo'] as String?,
      );
}
```

- [ ] **Step 2: Rewrite the repository**

```dart
// lib/features/ledger/recurring_transaction_repository.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';

class RecurringTransactionRepository {
  RecurringTransactionRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<RecurringTransaction>> list(String householdId) async {
    final rows = await _client.from('recurring_transactions').select().eq('household_id', householdId);
    return rows.map(RecurringTransaction.fromJson).toList();
  }

  Future<RecurringTransaction> create({
    required String householdId,
    required String accountId,
    required String categoryId,
    required String createdBy,
    required String ownerMemberId,
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime startAt,
    bool autoRegister = false,
    String? memo,
  }) async {
    final rows = await _client.from('recurring_transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'created_by': createdBy,
      'owner_member_id': ownerMemberId,
      'type': type,
      'amount': amount,
      'interval_rule': intervalRule,
      'start_at': startAt.toUtc().toIso8601String(),
      'auto_register': autoRegister,
      'memo': memo,
    }).select();
    return RecurringTransaction.fromJson(rows.first);
  }

  /// Updates an existing template. Unlike the old `next_run_at`-based
  /// design, `start_at` is a fixed calculation anchor, not a pointer another
  /// session might be mid-advancing — "done" is now derived from whether a
  /// matching transaction exists (the unique index from migration 0011),
  /// not from this column. Moving it can only change which future dates get
  /// computed as due; it can never resurrect or duplicate a past occurrence.
  /// So unlike the old `update()`, `startAt` is a plain required field here
  /// — no CAS, no optional-omit-when-unchanged dance needed.
  Future<RecurringTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String ownerMemberId,
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime startAt,
    required bool autoRegister,
    String? memo,
  }) async {
    final rows = await _client
        .from('recurring_transactions')
        .update({
          'account_id': accountId,
          'category_id': categoryId,
          'owner_member_id': ownerMemberId,
          'type': type,
          'amount': amount,
          'interval_rule': intervalRule,
          'start_at': startAt.toUtc().toIso8601String(),
          'auto_register': autoRegister,
          'memo': memo,
        })
        .eq('id', id)
        .select();
    return RecurringTransaction.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('recurring_transactions').delete().eq('id', id);
  }
}
```

- [ ] **Step 3: Rewrite the repository test**

```dart
// test/features/ledger/recurring_transaction_repository_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late RecurringTransactionRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = RecurringTransactionRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  Map<String, dynamic> _row({
    String id = 'rt-1',
    String ownerMemberId = 'member-1',
    String startAt = '2026-09-06T21:00:00.000Z',
    bool autoRegister = false,
  }) => {
        'id': id,
        'account_id': 'account-1',
        'category_id': 'category-1',
        'created_by': 'member-1',
        'owner_member_id': ownerMemberId,
        'type': 'expense',
        'amount': 50000,
        'interval_rule': 'MONTHLY',
        'start_at': startAt,
        'auto_register': autoRegister,
        'memo': null,
      };

  test('list parses start_at as local time and auto_register/owner_member_id, not UTC', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/recurring_transactions'));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_row(ownerMemberId: 'member-2', autoRegister: true)]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.startAt.isUtc, isFalse);
    expect(result.first.ownerMemberId, 'member-2');
    expect(result.first.autoRegister, isTrue);
  });

  test('create sends start_at converted to UTC, owner_member_id, and auto_register', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      ownerMemberId: 'member-2',
      type: 'expense',
      amount: 50000,
      intervalRule: 'MONTHLY',
      startAt: DateTime.parse('2026-09-05T21:00:00.000Z').toLocal(),
      autoRegister: true,
    );

    final request = await mockServer.first;
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    expect(body['start_at'], '2026-09-05T21:00:00.000Z');
    expect(body['owner_member_id'], 'member-2');
    expect(body['auto_register'], true);
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_row(ownerMemberId: 'member-2', startAt: '2026-09-05T21:00:00.000Z', autoRegister: true)]));
    await request.response.close();

    await future;
  });

  test('update sends every field including start_at, unconditionally', () async {
    final future = repo.update(
      id: 'rt-1',
      accountId: 'account-2',
      categoryId: 'category-2',
      ownerMemberId: 'member-2',
      type: 'income',
      amount: 100000,
      intervalRule: 'WEEKLY',
      startAt: DateTime.parse('2026-11-05T21:00:00.000Z').toLocal(),
      autoRegister: true,
      memo: 'Updated memo',
    );

    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.rt-1');
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    expect(body, {
      'account_id': 'account-2',
      'category_id': 'category-2',
      'owner_member_id': 'member-2',
      'type': 'income',
      'amount': 100000,
      'interval_rule': 'WEEKLY',
      'start_at': '2026-11-05T21:00:00.000Z',
      'auto_register': true,
      'memo': 'Updated memo',
    });
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_row(ownerMemberId: 'member-2', startAt: '2026-11-05T21:00:00.000Z', autoRegister: true)]));
    await request.response.close();

    await future;
  });

  test('delete removes a template by id', () async {
    final future = repo.delete('rt-1');

    final request = await mockServer.first;
    expect(request.method, 'DELETE');
    expect(request.uri.queryParameters['id'], 'eq.rt-1');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });
}
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/features/ledger/recurring_transaction_repository_test.dart`
Expected: all PASS. (This will fail to compile until Step 1–2 land — that's expected mid-task.)

- [ ] **Step 5: Commit**

```bash
git add lib/features/ledger/models/recurring_transaction.dart lib/features/ledger/recurring_transaction_repository.dart test/features/ledger/recurring_transaction_repository_test.dart
git commit -m "refactor(recurring): owner/auto-register/start_at fields, drop CAS advanceNextRunAt"
```

---

### Task 3: `missingOccurrences` pure function

**Files:**
- Modify: `lib/features/ledger/recurring_transaction_schedule.dart`
- Modify: `test/features/ledger/recurring_transaction_schedule_test.dart`

**Interfaces:**
- Consumes: `RecurringTransaction.startAt`/`.intervalRule` (Task 2), `advanceOccurrence` (unchanged, this file).
- Produces: `List<DateTime> missingOccurrences(RecurringTransaction template, {required DateTime now, required Set<DateTime> existingOccurredAt})` — used by both Task 5 (catch-up service) and Task 6 (todo screen).

- [ ] **Step 1: Add the function**

```dart
// lib/features/ledger/recurring_transaction_schedule.dart — add at the top:
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';

// (keep existing maxCatchUpOccurrences, _weekdayCodes, advanceOccurrence unchanged)

/// Every occurrence [template] should have between its `startAt` and [now]
/// (inclusive), excluding dates already covered by [existingOccurredAt].
/// Compared by instant (`.toUtc()`), never by local calendar fields — an
/// entry in [existingOccurredAt] may or may not already be
/// `.toLocal()`-converted depending on which caller read it, and comparing
/// raw DateTime values could silently miss a real match.
///
/// ponytail: capped at [maxCatchUpOccurrences] occurrences EXAMINED per
/// call — the same cap that bounds silent auto-creation also bounds how far
/// back the todo screen walks per template per load. Raise it (or split
/// into a separate, todo-specific constant) only if a real household's
/// overdue backlog is ever big enough to hit it in practice.
List<DateTime> missingOccurrences(
  RecurringTransaction template, {
  required DateTime now,
  required Set<DateTime> existingOccurredAt,
}) {
  final existingUtc = existingOccurredAt.map((d) => d.toUtc()).toSet();
  final missing = <DateTime>[];
  var cursor = template.startAt;
  var visited = 0;
  while (!cursor.isAfter(now) && visited < maxCatchUpOccurrences) {
    if (!existingUtc.contains(cursor.toUtc())) {
      missing.add(cursor);
    }
    visited++;
    cursor = advanceOccurrence(template.intervalRule, cursor);
  }
  return missing;
}
```

- [ ] **Step 2: Write the failing tests**

```dart
// test/features/ledger/recurring_transaction_schedule_test.dart — add:
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';

// (keep every existing advanceOccurrence/maxCatchUpOccurrences test as-is; add:)

RecurringTransaction _template({
  required DateTime startAt,
  String intervalRule = 'DAILY',
}) =>
    RecurringTransaction(
      id: 'rt-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      ownerMemberId: 'member-1',
      type: 'expense',
      amount: 1000,
      intervalRule: intervalRule,
      startAt: startAt,
      autoRegister: false,
    );

void main() {
  // ... existing tests ...

  group('missingOccurrences', () {
    test('returns every date from startAt through now when nothing exists yet', () {
      final template = _template(startAt: DateTime(2026, 9, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(template, now: DateTime(2026, 9, 4), existingOccurredAt: {});
      expect(missing, [
        DateTime(2026, 9, 1),
        DateTime(2026, 9, 2),
        DateTime(2026, 9, 3),
        DateTime(2026, 9, 4),
      ]);
    });

    test('excludes a date that already has a matching transaction', () {
      final template = _template(startAt: DateTime(2026, 9, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(
        template,
        now: DateTime(2026, 9, 3),
        existingOccurredAt: {DateTime(2026, 9, 2)},
      );
      expect(missing, [DateTime(2026, 9, 1), DateTime(2026, 9, 3)]);
    });

    test('matches an existing date by instant, not by local representation', () {
      // existingOccurredAt holds a UTC-flagged DateTime for the same instant
      // as the second expected occurrence — must still be recognized as a match.
      final template = _template(startAt: DateTime(2026, 9, 1), intervalRule: 'DAILY');
      final secondOccurrenceUtc = DateTime(2026, 9, 2).toUtc();
      final missing = missingOccurrences(
        template,
        now: DateTime(2026, 9, 2),
        existingOccurredAt: {secondOccurrenceUtc},
      );
      expect(missing, [DateTime(2026, 9, 1)]);
    });

    test('returns nothing when startAt is after now', () {
      final template = _template(startAt: DateTime(2026, 10, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(template, now: DateTime(2026, 9, 1), existingOccurredAt: {});
      expect(missing, isEmpty);
    });

    test('stops examining after maxCatchUpOccurrences even if all are missing', () {
      final template = _template(startAt: DateTime(2026, 1, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(template, now: DateTime(2026, 12, 31), existingOccurredAt: {});
      expect(missing, hasLength(maxCatchUpOccurrences));
      expect(missing.last, DateTime(2026, 1, 1).add(Duration(days: maxCatchUpOccurrences - 1)));
    });
  });
}
```

- [ ] **Step 3: Run the tests**

Run: `flutter test test/features/ledger/recurring_transaction_schedule_test.dart`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/features/ledger/recurring_transaction_schedule.dart test/features/ledger/recurring_transaction_schedule_test.dart
git commit -m "feat(recurring): add missingOccurrences, the shared expected-vs-existing diff"
```

---

### Task 4: TransactionRepository — confirmed, recurring_transaction_id, occurrence lookup

**Files:**
- Modify: `lib/features/ledger/transaction_repository.dart`
- Create: `test/features/ledger/transaction_repository_confirmed_test.dart`

**Interfaces:**
- Produces: `TransactionRepository.create({..., String? recurringTransactionId, bool confirmed = true})`, `.list(householdId, {bool? confirmed})`, `.confirm(String id)`, `.occurredAtsForRecurringTransaction(String recurringTransactionId) -> Future<Set<DateTime>>`.

- [ ] **Step 1: Modify `list` and `create`, add `confirm` and `occurredAtsForRecurringTransaction`**

```dart
// lib/features/ledger/transaction_repository.dart
  Future<List<LedgerTransaction>> list(String householdId, {bool? confirmed}) async {
    var query = _client
        .from('transactions')
        .select('*, transaction_tags(tag_id)')
        .eq('household_id', householdId);
    if (confirmed != null) {
      query = query.eq('confirmed', confirmed);
    }
    final rows = await query.order('occurred_at', ascending: false);
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
    List<String> tagIds = const [],
    DateTime? occurredAt,
    String? recurringTransactionId,
    bool confirmed = true,
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
      'confirmed': confirmed,
      if (occurredAt != null) 'occurred_at': occurredAt.toUtc().toIso8601String(),
      if (recurringTransactionId != null) 'recurring_transaction_id': recurringTransactionId,
    }).select();
    final transaction = LedgerTransaction.fromJson(rows.first);
    if (tagIds.isNotEmpty) {
      await setTags(transaction.id, tagIds);
    }
    return LedgerTransaction.fromJson({...rows.first, 'transaction_tags': tagIds.map((id) => {'tag_id': id}).toList()});
  }

  /// Flips a notification-capture "확인 후 저장" pending transaction to confirmed.
  Future<void> confirm(String id) async {
    await _client.from('transactions').update({'confirmed': true}).eq('id', id);
  }

  /// Every `occurred_at` already recorded for [recurringTransactionId] —
  /// used by `missingOccurrences` to compute what's still due.
  Future<Set<DateTime>> occurredAtsForRecurringTransaction(String recurringTransactionId) async {
    final rows = await _client
        .from('transactions')
        .select('occurred_at')
        .eq('recurring_transaction_id', recurringTransactionId);
    return rows.map((r) => DateTime.parse(r['occurred_at'] as String)).toSet();
  }
```

(Leave `update`, `setTags`, `delete` unchanged.)

- [ ] **Step 2: Write the tests**

```dart
// test/features/ledger/transaction_repository_confirmed_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late TransactionRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = TransactionRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  // confirmed/recurring_transaction_id are real response columns as of
  // migration 0011, included here for a realistic mock even though
  // LedgerTransaction.fromJson doesn't parse them (nothing in this plan's
  // UI needs them on the model — see Task 4's note).
  Map<String, dynamic> _txnRow({bool confirmed = true, String? recurringTransactionId}) => {
        'id': 'txn-1',
        'account_id': 'account-1',
        'category_id': 'category-1',
        'member_id': 'member-1',
        'type': 'expense',
        'amount': 1000,
        'occurred_at': '2026-09-01T00:00:00.000Z',
        'source': 'recurring_auto',
        'memo': null,
        'merchant': null,
        'confirmed': confirmed,
        'recurring_transaction_id': recurringTransactionId,
      };

  test('list adds a confirmed filter only when confirmed is non-null', () async {
    final future = repo.list('household-1', confirmed: true);
    final request = await mockServer.first;
    expect(request.uri.queryParameters['confirmed'], 'eq.true');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_txnRow()]));
    await request.response.close();
    await future;
  });

  test('list omits the confirmed filter when confirmed is null', () async {
    final future = repo.list('household-1');
    final request = await mockServer.first;
    expect(request.uri.queryParameters.containsKey('confirmed'), isFalse);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_txnRow()]));
    await request.response.close();
    await future;
  });

  test('create sends confirmed and recurring_transaction_id', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      memberId: 'member-1',
      type: 'expense',
      amount: 1000,
      source: 'recurring_auto',
      recurringTransactionId: 'rt-1',
      confirmed: false,
    );
    final request = await mockServer.first;
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    expect(body['confirmed'], false);
    expect(body['recurring_transaction_id'], 'rt-1');
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_txnRow(confirmed: false, recurringTransactionId: 'rt-1')]));
    await request.response.close();
    await future;
  });

  test('confirm sets confirmed to true by id', () async {
    final future = repo.confirm('txn-1');
    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.txn-1');
    expect(jsonDecode(await utf8.decodeStream(request)), {'confirmed': true});
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    await future;
  });

  test('occurredAtsForRecurringTransaction returns the set of existing occurred_at values', () async {
    final future = repo.occurredAtsForRecurringTransaction('rt-1');
    final request = await mockServer.first;
    expect(request.uri.queryParameters['recurring_transaction_id'], 'eq.rt-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'occurred_at': '2026-09-01T00:00:00.000Z'},
        {'occurred_at': '2026-10-01T00:00:00.000Z'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, {DateTime.parse('2026-09-01T00:00:00.000Z'), DateTime.parse('2026-10-01T00:00:00.000Z')});
  });
}
```

- [ ] **Step 3: Run the tests**

Run: `flutter test test/features/ledger/transaction_repository_confirmed_test.dart`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/features/ledger/transaction_repository.dart test/features/ledger/transaction_repository_confirmed_test.dart
git commit -m "feat(transactions): confirmed flag, recurring_transaction_id, occurrence lookup"
```

---

### Task 5: Catch-up service rewrite — insert-and-ignore-conflict, auto_register only

**Files:**
- Modify: `lib/features/ledger/recurring_transaction_catchup_service.dart`
- Modify: `test/features/ledger/recurring_transaction_catchup_service_test.dart`

**Interfaces:**
- Consumes: `missingOccurrences` (Task 3), `TransactionRepository.occurredAtsForRecurringTransaction`/`.create(..., recurringTransactionId:)` (Task 4), `RecurringTransaction.autoRegister`/`.ownerMemberId` (Task 2).
- Produces: `RecurringTransactionCatchUpService.run(householdId, {now})` unchanged signature; only `auto_register=true` templates are processed now.

- [ ] **Step 1: Rewrite the service**

```dart
// lib/features/ledger/recurring_transaction_catchup_service.dart
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_repository.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_schedule.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

class RecurringTransactionCatchUpService {
  RecurringTransactionCatchUpService({
    required this.recurringTransactionRepository,
    required this.transactionRepository,
  });

  final RecurringTransactionRepository recurringTransactionRepository;
  final TransactionRepository transactionRepository;

  /// Silently creates every occurrence an `auto_register=true` template is
  /// behind on, for [householdId]. Concurrency is no longer this service's
  /// concern: `transactions_recurring_occurrence_unique` (a DB-level partial
  /// unique index) makes a duplicate insert fail outright, so two
  /// overlapping runs (e.g. both household members opening the app at the
  /// same moment) each simply attempt every missing date, and whichever
  /// insert loses the race is rejected by Postgres and ignored here.
  /// `auto_register=false` templates are skipped entirely — their missing
  /// occurrences surface in the todo screen (Task 6) instead. Returns how
  /// many transactions were actually created.
  ///
  /// [now] defaults to the real current time; tests pass a fixed value so
  /// the "is this due yet" cutoff is deterministic.
  Future<int> run(String householdId, {DateTime? now}) async {
    final cutoff = now ?? DateTime.now();
    final templates = await recurringTransactionRepository.list(householdId);
    var createdCount = 0;

    for (final template in templates.where((t) => t.autoRegister)) {
      final existing = await transactionRepository.occurredAtsForRecurringTransaction(template.id);
      final missing = missingOccurrences(template, now: cutoff, existingOccurredAt: existing);
      for (final occurrenceDate in missing) {
        try {
          await transactionRepository.create(
            householdId: householdId,
            accountId: template.accountId,
            categoryId: template.categoryId,
            memberId: template.ownerMemberId,
            type: template.type,
            amount: template.amount,
            memo: template.memo,
            source: 'recurring_auto',
            occurredAt: occurrenceDate,
            recurringTransactionId: template.id,
          );
          createdCount++;
        } on PostgrestException catch (e) {
          // 23505 = unique_violation — another session created this exact
          // occurrence between our read and our insert. See Global
          // Constraints for why this is the correct check.
          if (e.code != '23505') rethrow;
        }
      }
    }

    return createdCount;
  }
}

final recurringTransactionRepository = RecurringTransactionRepository(client: supabase);
final recurringTransactionCatchUpService = RecurringTransactionCatchUpService(
  recurringTransactionRepository: recurringTransactionRepository,
  transactionRepository: transactionRepository,
);
```

- [ ] **Step 2: Rewrite the test file**

```dart
// test/features/ledger/recurring_transaction_catchup_service_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_repository.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late RecurringTransactionCatchUpService service;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    service = RecurringTransactionCatchUpService(
      recurringTransactionRepository: RecurringTransactionRepository(client: client),
      transactionRepository: TransactionRepository(client: client),
    );
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  Map<String, dynamic> _templateRow({
    String id = 'rt-1',
    String intervalRule = 'MONTHLY',
    required String startAt,
    bool autoRegister = true,
  }) =>
      {
        'id': id,
        'account_id': 'account-1',
        'category_id': 'category-1',
        'created_by': 'member-1',
        'owner_member_id': 'member-1',
        'type': 'expense',
        'amount': 50000,
        'interval_rule': intervalRule,
        'start_at': startAt,
        'auto_register': autoRegister,
        'memo': '월세',
      };

  test('creates one transaction per missing occurrence for an auto_register template', () async {
    final requests = StreamIterator<HttpRequest>(mockServer);
    // MONTHLY from 2026-07-15, checked as of 2026-08-20: July 15 and August 15
    // are both due; September 15 is not yet (it's after the cutoff).
    final future = service.run('household-1', now: DateTime.utc(2026, 8, 20));

    await requests.moveNext();
    final listRequest = requests.current;
    await listRequest.drain<void>();
    listRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_templateRow(startAt: DateTime.utc(2026, 7, 15).toIso8601String())]));
    await listRequest.response.close();

    // occurredAtsForRecurringTransaction — nothing created yet
    await requests.moveNext();
    final occurredRequest = requests.current;
    await occurredRequest.drain<void>();
    occurredRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<dynamic>[]));
    await occurredRequest.response.close();

    // MONTHLY from 2026-07-15 through 2026-09-20 (cutoff) = July and August only
    for (final expectedDate in ['2026-07-15T00:00:00.000Z', '2026-08-15T00:00:00.000Z']) {
      await requests.moveNext();
      final txnRequest = requests.current;
      final body = jsonDecode(await utf8.decodeStream(txnRequest)) as Map<String, dynamic>;
      expect(body['occurred_at'], expectedDate);
      expect(body['recurring_transaction_id'], 'rt-1');
      txnRequest.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(jsonEncode([
          {
            'id': 'txn-$expectedDate', 'account_id': 'account-1', 'category_id': 'category-1',
            'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
            'occurred_at': expectedDate, 'source': 'recurring_auto', 'memo': '월세', 'merchant': null,
          },
        ]));
      await txnRequest.response.close();
    }

    expect(await future, 2);
    await requests.cancel();
  });

  test('skips a template entirely when auto_register is false', () async {
    final future = service.run('household-1', now: DateTime.utc(2026, 9, 20));

    final listRequest = await mockServer.first;
    await listRequest.drain<void>();
    listRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_templateRow(startAt: DateTime.utc(2026, 7, 15).toIso8601String(), autoRegister: false)]));
    await listRequest.response.close();

    // no further requests should follow — the mock server has nothing else
    // queued, so a second request would hang; the test's overall timeout
    // catches a regression that fires one.
    expect(await future, 0);
  });

  test('ignores a unique_violation from a concurrent duplicate and continues', () async {
    var txnAttempt = 0;

    mockServer.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/recurring_transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([_templateRow(intervalRule: 'DAILY', startAt: DateTime.utc(2026, 9, 1).toIso8601String())]));
        await request.response.close();
      } else if (request.method == 'GET' && request.uri.path.endsWith('/transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<dynamic>[]));
        await request.response.close();
      } else if (request.method == 'POST' && request.uri.path.endsWith('/transactions')) {
        txnAttempt++;
        await request.drain<void>();
        if (txnAttempt == 1) {
          // simulate a concurrent session having already created this exact occurrence
          request.response
            ..statusCode = HttpStatus.conflict
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'code': '23505', 'message': 'duplicate key value violates unique constraint'}));
        } else {
          request.response
            ..statusCode = HttpStatus.created
            ..headers.contentType = ContentType.json
            ..write(jsonEncode([
              {
                'id': 'txn-$txnAttempt', 'account_id': 'account-1', 'category_id': 'category-1',
                'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
                'occurred_at': DateTime.now().toUtc().toIso8601String(), 'source': 'recurring_auto',
                'memo': null, 'merchant': null,
              },
            ]));
        }
        await request.response.close();
      }
    });

    final count = await service.run('household-1', now: DateTime.utc(2026, 9, 2));

    // DAILY from Sep 1 through Sep 2 = 2 occurrences; the first attempt hits
    // the simulated duplicate and is ignored, the second succeeds.
    expect(count, 1);
    expect(txnAttempt, 2);
  });
}
```

- [ ] **Step 3: Run the tests**

Run: `flutter test test/features/ledger/recurring_transaction_catchup_service_test.dart`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/features/ledger/recurring_transaction_catchup_service.dart test/features/ledger/recurring_transaction_catchup_service_test.dart
git commit -m "refactor(recurring): catch-up uses insert-and-ignore-conflict, auto_register templates only"
```

---

### Task 6: 나/배우자 투두리스트 화면

**Files:**
- Modify: `lib/features/household/household_repository.dart`
- Create: `lib/features/ledger/recurring_transaction_todo_screen.dart`
- Create: `test/features/ledger/recurring_transaction_todo_screen_test.dart`

**Interfaces:**
- Consumes: `missingOccurrences` (Task 3), `RecurringTransactionRepository.list`, `TransactionRepository.occurredAtsForRecurringTransaction`/`.create` (Tasks 2, 4).
- Produces: `HouseholdRepository.myMemberId(String householdId) -> Future<String>`. `TodoItem` (public class: `template`, `occurrenceDate`), `splitTodoItems(templates, myMemberId, {required now, required existingOccurredAtByTemplateId}) -> ({List<TodoItem> mine, List<TodoItem> spouse})` (pure, unit-testable). `RecurringTransactionTodoScreen(householdId)` — a body-only widget (no own Scaffold/AppBar) for embedding in Task 8's TabBarView.

- [ ] **Step 1: Add `myMemberId` to HouseholdRepository**

```dart
// lib/features/household/household_repository.dart — add:
  /// The caller's own household_members.id within [householdId] — used
  /// wherever code needs to know "which member is me" (e.g. defaulting a
  /// new recurring-transaction template's owner, or splitting the
  /// recurring-transaction todo list into "나"/"배우자").
  Future<String> myMemberId(String householdId) async {
    final row = await _client
        .from('household_members')
        .select('id')
        .eq('household_id', householdId)
        .eq('user_id', _client.auth.currentUser!.id)
        .single();
    return row['id'] as String;
  }
```

- [ ] **Step 2: Write the todo screen with its pure split function**

```dart
// lib/features/ledger/recurring_transaction_todo_screen.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart' show recurringTransactionRepository;
import 'package:ppyu_budget/features/ledger/recurring_transaction_schedule.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;

class TodoItem {
  const TodoItem({required this.template, required this.occurrenceDate});
  final RecurringTransaction template;
  final DateTime occurrenceDate;
}

/// Pure so it can be unit-tested without a widget harness. Splits every
/// missing occurrence across [templates] (`auto_register=false` only) into
/// "mine" (owner is [myMemberId]) vs "spouse" (any other owner).
({List<TodoItem> mine, List<TodoItem> spouse}) splitTodoItems(
  List<RecurringTransaction> templates,
  String myMemberId, {
  required DateTime now,
  required Map<String, Set<DateTime>> existingOccurredAtByTemplateId,
}) {
  final mine = <TodoItem>[];
  final spouse = <TodoItem>[];
  for (final template in templates.where((t) => !t.autoRegister)) {
    final existing = existingOccurredAtByTemplateId[template.id] ?? const <DateTime>{};
    final missing = missingOccurrences(template, now: now, existingOccurredAt: existing);
    final bucket = template.ownerMemberId == myMemberId ? mine : spouse;
    bucket.addAll(missing.map((date) => TodoItem(template: template, occurrenceDate: date)));
  }
  return (mine: mine, spouse: spouse);
}

String _dateLabel(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Body content for the "처리할 목록" tab of the recurring-transaction home
/// screen (Task 8) — no own Scaffold/AppBar, embedded in a TabBarView.
class RecurringTransactionTodoScreen extends StatefulWidget {
  const RecurringTransactionTodoScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<RecurringTransactionTodoScreen> createState() => _RecurringTransactionTodoScreenState();
}

class _RecurringTransactionTodoScreenState extends State<RecurringTransactionTodoScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 2, vsync: this);
  List<TodoItem>? _mine;
  List<TodoItem>? _spouse;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final myMemberId = await householdRepository.myMemberId(widget.householdId);
      final templates = await recurringTransactionRepository.list(widget.householdId);
      final existingByTemplateId = <String, Set<DateTime>>{};
      for (final template in templates.where((t) => !t.autoRegister)) {
        existingByTemplateId[template.id] =
            await transactionRepository.occurredAtsForRecurringTransaction(template.id);
      }
      if (!mounted) return;
      final split = splitTodoItems(
        templates,
        myMemberId,
        now: DateTime.now(),
        existingOccurredAtByTemplateId: existingByTemplateId,
      );
      setState(() {
        _mine = split.mine;
        _spouse = split.spouse;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '처리할 목록을 불러오지 못했어요');
    }
  }

  Future<void> _confirm(TodoItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('거래 등록'),
        content: Text('${_dateLabel(item.occurrenceDate)}에 ${item.template.amount}원을 등록할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('등록')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await transactionRepository.create(
        householdId: widget.householdId,
        accountId: item.template.accountId,
        categoryId: item.template.categoryId,
        memberId: item.template.ownerMemberId,
        type: item.template.type,
        amount: item.template.amount,
        memo: item.template.memo,
        source: 'recurring_auto',
        occurredAt: item.occurrenceDate,
        recurringTransactionId: item.template.id,
      );
    } on PostgrestException catch (e) {
      // 23505 — 배우자가 먼저 처리한 경우: 에러 없이 목록만 새로고침하면 됨
      if (e.code != '23505') {
        if (mounted) setState(() => _error = '등록에 실패했어요');
        return;
      }
    } catch (e) {
      if (mounted) setState(() => _error = '등록에 실패했어요');
      return;
    }
    await _load();
  }

  Widget _list(List<TodoItem>? items) {
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return const Center(child: Text('처리할 항목이 없어요'));
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final sign = item.template.type == 'expense' ? '-' : '+';
        return ListTile(
          title: Text('$sign${item.template.amount}원 · ${_dateLabel(item.occurrenceDate)}'),
          subtitle: item.template.memo != null ? Text(item.template.memo!) : null,
          onTap: () => _confirm(item),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(controller: _tabController, tabs: const [Tab(text: '나'), Tab(text: '배우자')]),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: TabBarView(controller: _tabController, children: [_list(_mine), _list(_spouse)]),
        ),
      ],
    );
  }
}
```

- [ ] **Step 3: Write the pure-function test**

```dart
// test/features/ledger/recurring_transaction_todo_screen_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_todo_screen.dart';

RecurringTransaction _template({
  required String id,
  required String ownerMemberId,
  bool autoRegister = false,
}) =>
    RecurringTransaction(
      id: id,
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      ownerMemberId: ownerMemberId,
      type: 'expense',
      amount: 1000,
      intervalRule: 'DAILY',
      startAt: DateTime(2026, 9, 1),
      autoRegister: autoRegister,
    );

void main() {
  test('buckets a missing occurrence under "mine" when the template owner is me', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'me')],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {},
    );
    expect(result.mine, hasLength(1));
    expect(result.spouse, isEmpty);
  });

  test('buckets a missing occurrence under "spouse" when the template owner is not me', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'spouse-id')],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {},
    );
    expect(result.mine, isEmpty);
    expect(result.spouse, hasLength(1));
  });

  test('excludes an auto_register template entirely — it has no todo items', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'me', autoRegister: true)],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {},
    );
    expect(result.mine, isEmpty);
    expect(result.spouse, isEmpty);
  });

  test('excludes a date already covered by an existing transaction', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'me')],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {
        'rt-1': {DateTime(2026, 9, 1)},
      },
    );
    expect(result.mine, isEmpty);
  });
}
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/features/ledger/recurring_transaction_todo_screen_test.dart`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/household/household_repository.dart lib/features/ledger/recurring_transaction_todo_screen.dart test/features/ledger/recurring_transaction_todo_screen_test.dart
git commit -m "feat(recurring): 나/배우자 처리할 목록 화면"
```

---

### Task 7: Template management screen — owner/자동등록 fields, badges

**Files:**
- Modify: `lib/features/ledger/recurring_transaction_screen.dart`

**Interfaces:**
- Consumes: `RecurringTransactionRepository.create`/`.update` (Task 2, new signatures), `HouseholdRepository.myMemberId`/`.nicknamesByMemberId` (Task 6, existing).
- Produces: no new public interface — this is the leaf UI. `RecurringTransactionListScreen` drops its own `AppBar` (Task 8 supplies one via the new TabBar host) but keeps its `Scaffold`/`FloatingActionButton` (a `Scaffold` without `appBar` nested inside a `TabBarView` tab is a normal, supported Flutter pattern — it still gets its own FAB).

- [ ] **Step 1: Update the list screen — drop its AppBar, relabel, add auto/confirm badge**

```dart
// lib/features/ledger/recurring_transaction_screen.dart
// Replace the whole build() method of _RecurringTransactionListScreenState:
  @override
  Widget build(BuildContext context) {
    final templates = _templates;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RecurringTransactionFormScreen(householdId: widget.householdId),
          ));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: templates == null
                ? const Center(child: CircularProgressIndicator())
                : templates.isEmpty
                    ? const Center(child: Text('등록된 반복거래가 없어요'))
                    : ListView.builder(
                        itemCount: templates.length,
                        itemBuilder: (context, i) {
                          final t = templates[i];
                          final sign = t.type == 'expense' ? '-' : '+';
                          return ListTile(
                            title: Text('$sign${t.amount}원 · ${_ruleLabel(t.intervalRule)}'),
                            subtitle: Text('시작일: ${t.startAt.year}-${t.startAt.month.toString().padLeft(2, '0')}-${t.startAt.day.toString().padLeft(2, '0')}'),
                            trailing: Chip(label: Text(t.autoRegister ? '자동' : '확인 후 등록')),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => RecurringTransactionFormScreen(
                                  householdId: widget.householdId,
                                  existing: t,
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
```

(Remove the now-unused `appBar:` block and its `AppBar(title: const Text('반복거래 관리'))` — the Task 8 host screen supplies the title/AppBar instead. Leave `_ruleLabel`, `initState`, `_load` unchanged.)

- [ ] **Step 2: Update the form screen — owner dropdown, auto_register switch, rename `_nextRunAt`→`_startAt`, simplify `_save`**

```dart
// lib/features/ledger/recurring_transaction_screen.dart — in _RecurringTransactionFormScreenState:

// field renames/additions (replace the existing field block):
  late final _amountController = TextEditingController(text: widget.existing?.amount.toString() ?? '');
  late final _memoController = TextEditingController(text: widget.existing?.memo ?? '');
  late String _type = widget.existing?.type ?? 'expense';
  late DateTime _startAt = widget.existing?.startAt ?? DateTime.now();
  late bool _autoRegister = widget.existing?.autoRegister ?? false;
  late _Frequency _frequency = _parseFrequency(widget.existing?.intervalRule);
  late final Set<String> _selectedWeekdays = _parseWeekdays(widget.existing?.intervalRule);
  List<Account>? _accounts;
  List<Category>? _categories;
  String? _accountId;
  String? _categoryId;
  Map<String, String>? _nicknames;
  String? _ownerMemberId;
  String? _error;
  bool _saving = false;

// initState: also preload owner options, defaulting a NEW template's owner to "me"
  @override
  void initState() {
    super.initState();
    _accountId = widget.existing?.accountId;
    _categoryId = widget.existing?.categoryId;
    _ownerMemberId = widget.existing?.ownerMemberId;
    _loadOptions();
    _loadOwnerOptions();
  }

  Future<void> _loadOwnerOptions() async {
    try {
      final nicknames = await householdRepository.nicknamesByMemberId(widget.householdId);
      String? defaultOwner = _ownerMemberId;
      if (defaultOwner == null) {
        defaultOwner = await householdRepository.myMemberId(widget.householdId);
      }
      if (!mounted) return;
      setState(() {
        _nicknames = nicknames;
        _ownerMemberId = nicknames.containsKey(defaultOwner) ? defaultOwner : (nicknames.isNotEmpty ? nicknames.keys.first : null);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '가구 구성원을 불러오지 못했어요');
    }
  }

// _pickDate: rename target field
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _startAt = DateTime(picked.year, picked.month, picked.day, _startAt.hour, _startAt.minute));
  }

// _save: add ownerMemberId/autoRegister validation and pass-through, drop the optional-startAt dance
  Future<void> _save() async {
    final amount = int.tryParse(_amountController.text.trim());
    final accountId = _accountId;
    final categoryId = _categoryId;
    final ownerMemberId = _ownerMemberId;
    if (amount == null || amount <= 0 || accountId == null || categoryId == null || ownerMemberId == null) {
      setState(() => _error = '금액, 계좌, 카테고리, 소유자를 확인해주세요');
      return;
    }
    if (_frequency == _Frequency.weekly && _selectedWeekdays.isEmpty) {
      setState(() => _error = '반복할 요일을 하나 이상 선택해주세요');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      final memo = _memoController.text.trim().isEmpty ? null : _memoController.text.trim();
      if (existing == null) {
        final myId = await householdRepository.myMemberId(widget.householdId);
        await recurringTransactionRepository.create(
          householdId: widget.householdId,
          accountId: accountId,
          categoryId: categoryId,
          createdBy: myId,
          ownerMemberId: ownerMemberId,
          type: _type,
          amount: amount,
          intervalRule: _intervalRule,
          startAt: _startAt,
          autoRegister: _autoRegister,
          memo: memo,
        );
      } else {
        await recurringTransactionRepository.update(
          id: existing.id,
          accountId: accountId,
          categoryId: categoryId,
          ownerMemberId: ownerMemberId,
          type: _type,
          amount: amount,
          intervalRule: _intervalRule,
          startAt: _startAt,
          autoRegister: _autoRegister,
          memo: memo,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '반복거래 저장에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

// build(): rename the date ListTile, add owner dropdown + auto_register switch
// (replace the "시작일(다음 실행일)" ListTile and everything after the memo TextField with:)
            if (_nicknames != null && _nicknames!.isNotEmpty)
              DropdownButton<String>(
                value: _ownerMemberId,
                items: _nicknames!.entries.map((e) => DropdownMenuItem(value: e.key, child: Text('소유자: ${e.value}'))).toList(),
                onChanged: (v) => setState(() => _ownerMemberId = v),
              ),
            SwitchListTile(
              title: const Text('자동 등록'),
              subtitle: const Text('꺼두면 "처리할 목록"에서 확인 후 등록해요'),
              value: _autoRegister,
              onChanged: (v) => setState(() => _autoRegister = v),
            ),
            ListTile(
              title: const Text('시작일'),
              subtitle: Text('${_startAt.year}-${_startAt.month.toString().padLeft(2, '0')}-${_startAt.day.toString().padLeft(2, '0')}'),
              onTap: _pickDate,
            ),
```

Add the import needed for `householdRepository`:

```dart
// lib/features/ledger/recurring_transaction_screen.dart — add near the top imports:
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
```

(Remove the now-dead inline `supabase.from('household_members')...` query and its now-unused `import 'package:ppyu_budget/core/supabase_client.dart';` if nothing else in the file uses `supabase` directly — check with a search before removing the import.)

- [ ] **Step 2: Run the analyzer**

Run: `flutter analyze lib/features/ledger/recurring_transaction_screen.dart`
Expected: no errors (unused-import warnings resolved by the check above).

- [ ] **Step 3: Commit**

```bash
git add lib/features/ledger/recurring_transaction_screen.dart
git commit -m "feat(recurring): owner/auto-register fields on the template form, auto/confirm badge on the list"
```

---

### Task 8: Recurring-transaction TabBar host + home-screen "자동거래등록" menu

**Files:**
- Create: `lib/features/ledger/recurring_transaction_home_screen.dart`
- Create: `lib/features/household/auto_registration_menu_screen.dart`
- Modify: `lib/features/household/home_screen.dart`

**Interfaces:**
- Consumes: `RecurringTransactionListScreen`, `RecurringTransactionTodoScreen` (Tasks 6, 7), `NotificationOnboardingScreen` (existing).
- Produces: `RecurringTransactionHomeScreen(householdId)`, `AutoRegistrationMenuScreen(householdId)` — both pushed from `HomeScreen`.

- [ ] **Step 1: Create the TabBar host**

```dart
// lib/features/ledger/recurring_transaction_home_screen.dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_screen.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_todo_screen.dart';

class RecurringTransactionHomeScreen extends StatefulWidget {
  const RecurringTransactionHomeScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<RecurringTransactionHomeScreen> createState() => _RecurringTransactionHomeScreenState();
}

class _RecurringTransactionHomeScreenState extends State<RecurringTransactionHomeScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('반복거래'),
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: '처리할 목록'), Tab(text: '템플릿 관리')]),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          RecurringTransactionTodoScreen(householdId: widget.householdId),
          RecurringTransactionListScreen(householdId: widget.householdId),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Create the menu screen**

```dart
// lib/features/household/auto_registration_menu_screen.dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_home_screen.dart';
import 'package:ppyu_budget/features/notification_capture/notification_onboarding_screen.dart';

class AutoRegistrationMenuScreen extends StatelessWidget {
  const AutoRegistrationMenuScreen({super.key, required this.householdId});

  final String householdId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('자동거래등록')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('반복거래'),
            subtitle: const Text('정기 결제/수입을 템플릿으로 등록하고 처리해요'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RecurringTransactionHomeScreen(householdId: householdId),
            )),
          ),
          ListTile(
            title: const Text('자동인식 거래'),
            subtitle: const Text('카드/은행 결제 알림을 자동으로 인식해요'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const NotificationOnboardingScreen(),
            )),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Rewire home_screen.dart**

```dart
// lib/features/household/home_screen.dart
// Replace this import:
// import 'package:ppyu_budget/features/ledger/recurring_transaction_screen.dart';
// import 'package:ppyu_budget/features/notification_capture/notification_onboarding_screen.dart';
// with:
import 'package:ppyu_budget/features/household/auto_registration_menu_screen.dart';

// Replace the two separate ListTiles —
//   '반복거래 관리' -> RecurringTransactionListScreen
//   '결제 알림 자동인식 설정' -> NotificationOnboardingScreen
// — with one:
            ListTile(
              title: const Text('자동거래등록'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AutoRegistrationMenuScreen(householdId: householdId),
              )),
            ),
```

Leave `recurring_transaction_catchup_service.dart`'s import (`show recurringTransactionCatchUpService`) and `_runCatchUp` untouched — auto-catch-up on app open is unaffected by this navigation change.

- [ ] **Step 4: Run the existing home_screen test**

Run: `flutter test test/features/household/home_screen_test.dart`
Expected: all PASS (these tests assert on `'거래 내역'`/invite-button visibility, not on the recurring/notification tiles, so they're unaffected).

- [ ] **Step 5: Commit**

```bash
git add lib/features/ledger/recurring_transaction_home_screen.dart lib/features/household/auto_registration_menu_screen.dart lib/features/household/home_screen.dart
git commit -m "feat(home): group 반복거래/자동인식 거래 under one 자동거래등록 menu"
```

---

### Task 9: Notification-capture confirm-mode setting

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/features/notification_capture/notification_settings.dart`
- Modify: `lib/features/notification_capture/notification_auto_save_service.dart`
- Modify: `test/features/notification_capture/notification_auto_save_service_test.dart`
- Create: `lib/features/notification_capture/notification_pending_screen.dart`
- Modify: `lib/features/notification_capture/notification_onboarding_screen.dart`

**Interfaces:**
- Consumes: `TransactionRepository.create(..., confirmed:)`/`.list(..., confirmed:)`/`.confirm` (Task 4).
- Produces: `NotificationSettings.confirmBeforeSave()`/`.setConfirmBeforeSave(bool)`, `NotificationPendingScreen(householdId)`.

- [ ] **Step 1: Add the dependency**

Run:
```bash
flutter pub add shared_preferences
```
Expected: `pubspec.yaml` gains a `shared_preferences: ^<resolved version>` line and `pubspec.lock` updates.

- [ ] **Step 2: Write the local setting**

```dart
// lib/features/notification_capture/notification_settings.dart
import 'package:shared_preferences/shared_preferences.dart';

/// Per-device setting (never synced through Supabase — a notification only
/// ever arrives on one spouse's phone, so this has no shared meaning across
/// the household). Controls whether NotificationAutoSaveService creates a
/// captured transaction already confirmed, or pending review.
class NotificationSettings {
  static const _key = 'notification_confirm_before_save';

  Future<bool> confirmBeforeSave() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> setConfirmBeforeSave(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final notificationSettings = NotificationSettings();
```

- [ ] **Step 3: Branch `NotificationAutoSaveService._handle` on the setting**

```dart
// lib/features/notification_capture/notification_auto_save_service.dart
// add import:
import 'package:ppyu_budget/features/notification_capture/notification_settings.dart';

// replace the final transactionRepository.create(...) call in _handle with:
    final confirmBeforeSave = await notificationSettings.confirmBeforeSave();
    await transactionRepository.create(
      householdId: householdId,
      accountId: accountId,
      categoryId: categoryId,
      memberId: memberId,
      type: 'expense',
      amount: parsed.amount,
      merchant: parsed.merchant,
      source: 'notification_auto',
      confirmed: !confirmBeforeSave,
    );
```

- [ ] **Step 4: Update the service test**

```dart
// test/features/notification_capture/notification_auto_save_service_test.dart
// add near the top imports:
import 'package:shared_preferences/shared_preferences.dart';

// add inside setUp(), before constructing `service`:
    SharedPreferences.setMockInitialValues({});
```

Add one new test (append inside `main()`, after the existing tests):

```dart
  test('creates a pending (unconfirmed) transaction when confirm-before-save is on', () async {
    SharedPreferences.setMockInitialValues({'notification_confirm_before_save': true});
    service.start();
    notificationController.add(notif('com.samsung.android.spay', '5,000원 승인 스타벅스'));

    await respondJson([]); // account lookup
    await respondJson([
      {'id': 'acc-1', 'name': '삼성페이', 'type': 'card'}
    ], status: 201); // account creation
    await respondJson([
      {'id': 'cat-1', 'name': '기타', 'type': 'expense', 'icon': null, 'is_default': true}
    ]); // category lookup
    final (txnInsert, txnBody) = await respondJson([
      {
        'id': 't1', 'account_id': 'acc-1', 'category_id': 'cat-1', 'member_id': 'member-1',
        'type': 'expense', 'amount': 5000, 'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'source': 'notification_auto', 'memo': null, 'merchant': '스타벅스',
      }
    ], status: 201);
    expect(txnInsert.uri.path, endsWith('/transactions'));
    final body = jsonDecode(txnBody) as Map<String, dynamic>;
    expect(body['confirmed'], false);
  });
```

(This test also needs `import 'dart:convert';` — already present in the file.)

- [ ] **Step 5: Run the test**

Run: `flutter test test/features/notification_capture/notification_auto_save_service_test.dart`
Expected: all PASS.

- [ ] **Step 6: Write the pending-review screen**

```dart
// lib/features/notification_capture/notification_pending_screen.dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;

class NotificationPendingScreen extends StatefulWidget {
  const NotificationPendingScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<NotificationPendingScreen> createState() => _NotificationPendingScreenState();
}

class _NotificationPendingScreenState extends State<NotificationPendingScreen> {
  List<LedgerTransaction>? _pending;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pending = await transactionRepository.list(widget.householdId, confirmed: false);
      if (!mounted) return;
      setState(() {
        _pending = pending;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '확인할 목록을 불러오지 못했어요');
    }
  }

  Future<void> _confirm(LedgerTransaction t) async {
    try {
      await transactionRepository.confirm(t.id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '확인 처리에 실패했어요');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      appBar: AppBar(title: const Text('자동인식 거래 확인')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: pending == null
                ? const Center(child: CircularProgressIndicator())
                : pending.isEmpty
                    ? const Center(child: Text('확인할 거래가 없어요'))
                    : ListView.builder(
                        itemCount: pending.length,
                        itemBuilder: (context, i) {
                          final t = pending[i];
                          final sign = t.type == 'expense' ? '-' : '+';
                          return ListTile(
                            title: Text('$sign${t.amount}원${t.merchant != null ? ' · ${t.merchant}' : ''}'),
                            trailing: TextButton(onPressed: () => _confirm(t), child: const Text('확인')),
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

- [ ] **Step 7: Wire the setting toggle and the pending screen into onboarding**

```dart
// lib/features/notification_capture/notification_onboarding_screen.dart
// add imports:
import 'package:ppyu_budget/features/notification_capture/notification_pending_screen.dart';
import 'package:ppyu_budget/features/notification_capture/notification_settings.dart';

// add this param + field to NotificationOnboardingScreen:
class NotificationOnboardingScreen extends StatefulWidget {
  const NotificationOnboardingScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<NotificationOnboardingScreen> createState() => _NotificationOnboardingScreenState();
}

// add to _NotificationOnboardingScreenState:
  bool? _confirmBeforeSave;

// in initState(), alongside _refresh():
    _loadSetting();

// add:
  Future<void> _loadSetting() async {
    final value = await notificationSettings.confirmBeforeSave();
    if (mounted) setState(() => _confirmBeforeSave = value);
  }

// add to build()'s Column children, after the '알림 접근 설정 열기' ElevatedButton block:
            const SizedBox(height: 24),
            SwitchListTile(
              title: const Text('확인 후 저장'),
              subtitle: const Text('꺼두면 인식된 거래가 바로 저장돼요. 켜두면 확인 후 저장 목록에서 검토 후 저장돼요.'),
              value: _confirmBeforeSave ?? false,
              onChanged: _confirmBeforeSave == null
                  ? null
                  : (v) async {
                      setState(() => _confirmBeforeSave = v);
                      await notificationSettings.setConfirmBeforeSave(v);
                    },
            ),
            if (_confirmBeforeSave == true)
              ElevatedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NotificationPendingScreen(householdId: widget.householdId),
                )),
                child: const Text('확인 후 저장 목록 보기'),
              ),
```

- [ ] **Step 8: Update the one existing call site**

```dart
// lib/features/household/auto_registration_menu_screen.dart (Task 8)
// change:
//   builder: (_) => const NotificationOnboardingScreen(),
// to:
              builder: (_) => NotificationOnboardingScreen(householdId: householdId),
```

- [ ] **Step 9: Run the full test suite**

Run: `flutter test`
Expected: all PASS.

- [ ] **Step 10: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/features/notification_capture/notification_settings.dart lib/features/notification_capture/notification_auto_save_service.dart test/features/notification_capture/notification_auto_save_service_test.dart lib/features/notification_capture/notification_pending_screen.dart lib/features/notification_capture/notification_onboarding_screen.dart lib/features/household/auto_registration_menu_screen.dart
git commit -m "feat(notification): local 확인 후 저장 setting + pending-review screen"
```

---

### Task 10: Main transaction list — hide unconfirmed rows

**Files:**
- Modify: `lib/features/ledger/transaction_list_screen.dart`

**Interfaces:**
- Consumes: `TransactionRepository.list(householdId, {confirmed})` (Task 4).

- [ ] **Step 1: Filter to confirmed rows**

```dart
// lib/features/ledger/transaction_list_screen.dart — in _load():
      final transactions = await transactionRepository.list(widget.householdId, confirmed: true);
```

This is a one-line call-site change onto a repository method already covered by Task 4's tests (`list` adds/omits the `confirmed` filter correctly) — no new test needed here per the codebase's existing convention of not separately testing a single filter argument passed at a call site (e.g. `stats_screen.dart`'s unfiltered `list()` call has no dedicated test either).

- [ ] **Step 2: Run the full test suite**

Run: `flutter test`
Expected: all PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/features/ledger/transaction_list_screen.dart
git commit -m "fix(transactions): main list hides unconfirmed (pending notification-review) rows"
```
