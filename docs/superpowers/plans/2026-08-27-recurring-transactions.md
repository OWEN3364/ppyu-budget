# 반복거래 자동등록 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 정기적으로 반복되는 지출/수입을 템플릿으로 등록하면, 앱 접속 시점에 밀린 횟수만큼 소급해서 실제 거래로 자동 등록한다.

**Architecture:** `recurring_transactions` 테이블에 반복 규칙(캘린더와 동일 형식)과 다음 실행일만 저장한다. 홈 화면 진입 시 밀린 템플릿을 찾아 발생 날짜를 하나씩 계산하며 `transactions`에 `source='recurring_auto'`로 실제 거래를 생성하고, 매 건 성공할 때마다 `next_run_at`을 그 자리에서 갱신한다(중간에 실패해도 이미 만든 만큼은 안전하게 보존). 서버 스케줄러 없음 — 클라이언트 체크만으로 동작.

**Tech Stack:** Flutter (Android), Supabase (Postgres+RLS+PostgREST)

**Spec:** `docs/superpowers/specs/2026-08-27-recurring-transactions-design.md`

## Global Constraints

- Android 단일 타겟.
- 모든 리포지토리 테스트는 실제 `SupabaseClient` + 로컬 `HttpServer`로 검증 (mocktail로 `.from()`/`.rpc()` 직접 모킹 금지).
- 새 테이블은 `alter table ... enable row level security`, `is_household_member(household_id)` 패턴 재사용. **insert 정책은 처음부터 `created_by`가 같은 가구 소속인지 검증한다** — 캘린더 phase에서 이 검증이 최초 스키마에 빠져 있어서 나중에 별도 마이그레이션으로 고친 전례가 있음, 이번엔 Task 1에서 바로 반영한다.
- **모든 `DateTime`을 다루는 모델의 `fromJson`은 반드시 `.toLocal()`을 호출한다.** 캘린더 phase 최종 리뷰에서 이걸 빠뜨려 UTC/로컬 시간대 불일치로 반복 계산이 틀리고 편집 시마다 9시간씩 밀리는 심각한 버그가 나왔던 전례가 있음 — 이번엔 Task 2의 모델 작성 시점부터 반영한다.
- 모든 async 위젯 메서드는 await 이후 `setState` 전에 `mounted` 체크, 저장/삭제류는 busy-guard bool로 중복 실행 방지.
- 파괴적 작업(삭제)엔 확인 다이얼로그 필수.
- 에러 메시지는 기존처럼 한국어, 사용자가 할 일 위주로 짧게.
- `interval_rule` 형식은 캘린더의 `recurrence_rule`과 완전히 동일: `DAILY` / `WEEKLY:MO,WE,FR` / `MONTHLY` / `YEARLY`. 다만 이 기능에서 `null`은 허용하지 않는다(반복 없는 반복거래는 의미가 없음).
- **월말 반복의 롤오버 처리가 캘린더와 다르다 — 의도적인 차이다.** 캘린더의 `expandOccurrences`는 31일에 시작한 MONTHLY 반복을 30일짜리 달에서 건너뛴다(화면에 안 보여줌, 부작용 없음). 반복거래는 실제 돈을 청구하는 템플릿이라 "이번 달은 청구를 건너뛴다"보다 "가장 가까운 유효한 날짜로 청구한다"가 사용자에게 덜 놀라운 동작이라고 판단해, `DateTime` 생성자의 자연스러운 롤오버(예: 1월 31일 반복 → 2월엔 3월 3일로 청구)를 그대로 사용한다. Task 3에서 이 차이를 명확히 코드 주석으로 남긴다.

---

### Task 1: 스키마 — recurring_transactions + transactions.source 확장

**Files:**
- Create: `supabase/migrations/0010_recurring_transactions.sql`
- Test: `supabase/tests/0010_recurring_transactions_test.sql`

**Interfaces:**
- Produces: `recurring_transactions(id, household_id, account_id, category_id, created_by, type, amount, memo, interval_rule, next_run_at, created_at)`, `transactions.source`가 `'recurring_auto'`도 허용

- [ ] **Step 1: 실제 source 제약 이름 확인**

Run (해당 작업 worktree에서, 프로젝트는 이미 링크되어 있음):
```bash
npx --yes supabase db query --linked --file - << 'EOF'
select conname from pg_constraint where conrelid = 'transactions'::regclass
  and contype = 'c' and pg_get_constraintdef(oid) ilike '%source%';
EOF
```
결과로 나온 실제 제약 이름을 Step 2의 `drop constraint`에 정확히 사용한다 (`0004_transaction_source_merchant.sql`에서 컬럼 레벨 `check`로 추가돼 Postgres가 자동 생성한 이름이라 `transactions_source_check`일 가능성이 높지만, 반드시 위 쿼리로 확인 후 사용— 이름이 다르면 그 이름을 쓴다).

- [ ] **Step 2: 마이그레이션 작성**

```sql
create table recurring_transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete restrict,
  category_id uuid not null references categories(id) on delete restrict,
  created_by uuid not null references household_members(id) on delete restrict,
  type text not null check (type in ('income', 'expense')),
  amount integer not null check (amount > 0),
  memo text,
  interval_rule text not null,
  next_run_at timestamptz not null,
  created_at timestamptz not null default now()
);

alter table recurring_transactions enable row level security;

create policy "members can select recurring_transactions" on recurring_transactions for select using (is_household_member(household_id));
create policy "members can insert recurring_transactions" on recurring_transactions for insert with check (
  is_household_member(household_id)
  and exists (select 1 from household_members m where m.id = created_by and m.household_id = recurring_transactions.household_id)
);
create policy "members can update recurring_transactions" on recurring_transactions for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete recurring_transactions" on recurring_transactions for delete using (is_household_member(household_id));

-- widen transactions.source so recurring-transaction catch-up can tag what
-- it creates. Replace <실제_제약_이름> below with the name found in Step 1.
alter table transactions drop constraint <실제_제약_이름>;
alter table transactions add constraint transactions_source_check
  check (source in ('manual', 'notification_auto', 'recurring_auto'));
```

- [ ] **Step 3: 적용**

Run: `npx --yes supabase db push --linked`

- [ ] **Step 4: SQL 테스트 작성**

기존 `supabase/tests/0009_fix_calendar_timezone_and_rls_test.sql`와 동일한 `begin;`/`savepoint`/`rollback to savepoint` 패턴, `set local role authenticated;`는 파일당 한 번만 최상단에.

```sql
-- Run with: supabase db query --linked --file supabase/tests/0010_recurring_transactions_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- a non-member household can't see a recurring_transactions row
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_template_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;
  insert into recurring_transactions (household_id, account_id, category_id, created_by, type, amount, interval_rule, next_run_at)
  values (v_household_a, v_account_a, v_category_a, v_member_a, 'expense', 50000, 'MONTHLY', now())
  returning id into v_template_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select count(*) into v_count from recurring_transactions where id = v_template_id;
  if v_count != 0 then
    raise exception 'TEST FAILED: household B could see household A''s recurring transaction';
  end if;
end $$;
rollback to savepoint sp1;

-- insert policy rejects a created_by that belongs to a DIFFERENT household
-- than the one being inserted into
savepoint sp2;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
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
  insert into accounts (household_id, name) values (v_household_a, '테스트카드') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and type = 'expense' limit 1;

  begin
    insert into recurring_transactions (household_id, account_id, category_id, created_by, type, amount, interval_rule, next_run_at)
    values (v_household_a, v_account_a, v_category_a, v_member_b, 'expense', 50000, 'MONTHLY', now());
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: insert should have been rejected for a created_by from a different household';
  end if;
end $$;
rollback to savepoint sp2;

-- transactions.source now accepts 'recurring_auto' and still rejects garbage
savepoint sp3;
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

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 10000, 'recurring_auto');

  begin
    insert into transactions (household_id, account_id, category_id, member_id, type, amount, source)
    values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 10000, 'garbage_value');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: an invalid source value should still be rejected';
  end if;
end $$;
rollback to savepoint sp3;

rollback;
```

- [ ] **Step 5: 테스트 실행**

Run: `npx --yes supabase db query --linked --file supabase/tests/0010_recurring_transactions_test.sql`
Expected: 에러 없이 종료

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0010_recurring_transactions.sql supabase/tests/0010_recurring_transactions_test.sql
git commit -m "feat(db): add recurring_transactions table and widen transactions.source"
```

---

### Task 2: RecurringTransaction 모델 + RecurringTransactionRepository

**Files:**
- Create: `lib/features/ledger/models/recurring_transaction.dart`
- Create: `lib/features/ledger/recurring_transaction_repository.dart`
- Test: `test/features/ledger/recurring_transaction_repository_test.dart`

**Interfaces:**
- Produces: `RecurringTransaction{id, accountId, categoryId, createdBy, type, amount, intervalRule, nextRunAt, memo}`, `RecurringTransactionRepository.list(householdId)`, `.create({...})`, `.update({...})`, `.delete(id)`, `.advanceNextRunAt(id, nextRunAt)`

- [ ] **Step 1: 모델**

`lib/features/ledger/models/recurring_transaction.dart`:
```dart
class RecurringTransaction {
  const RecurringTransaction({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.createdBy,
    required this.type,
    required this.amount,
    required this.intervalRule,
    required this.nextRunAt,
    this.memo,
  });

  final String id;
  final String accountId;
  final String categoryId;
  final String createdBy;
  final String type;
  final int amount;
  final String intervalRule;
  final DateTime nextRunAt;
  final String? memo;

  factory RecurringTransaction.fromJson(Map<String, dynamic> json) => RecurringTransaction(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        categoryId: json['category_id'] as String,
        createdBy: json['created_by'] as String,
        type: json['type'] as String,
        amount: json['amount'] as int,
        intervalRule: json['interval_rule'] as String,
        // See Global Constraints: PostgREST returns timestamptz with a UTC
        // suffix — .toLocal() here is what keeps every downstream date
        // calculation and display consistent (this is the exact bug class
        // caught in the shared-calendar phase; fixed at the model boundary
        // from the start this time).
        nextRunAt: DateTime.parse(json['next_run_at'] as String).toLocal(),
        memo: json['memo'] as String?,
      );
}
```

- [ ] **Step 2: RecurringTransactionRepository**

`lib/features/ledger/recurring_transaction_repository.dart`:
```dart
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
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime nextRunAt,
    String? memo,
  }) async {
    final rows = await _client.from('recurring_transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'created_by': createdBy,
      'type': type,
      'amount': amount,
      'interval_rule': intervalRule,
      'next_run_at': nextRunAt.toUtc().toIso8601String(),
      'memo': memo,
    }).select();
    return RecurringTransaction.fromJson(rows.first);
  }

  Future<RecurringTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime nextRunAt,
    String? memo,
  }) async {
    final rows = await _client
        .from('recurring_transactions')
        .update({
          'account_id': accountId,
          'category_id': categoryId,
          'type': type,
          'amount': amount,
          'interval_rule': intervalRule,
          'next_run_at': nextRunAt.toUtc().toIso8601String(),
          'memo': memo,
        })
        .eq('id', id)
        .select();
    return RecurringTransaction.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('recurring_transactions').delete().eq('id', id);
  }

  /// Advances only `next_run_at`, leaving every other field untouched — used
  /// by the catch-up service after each occurrence it successfully creates,
  /// so a mid-batch failure never loses the progress already made.
  Future<void> advanceNextRunAt(String id, DateTime nextRunAt) async {
    await _client
        .from('recurring_transactions')
        .update({'next_run_at': nextRunAt.toUtc().toIso8601String()})
        .eq('id', id);
  }
}
```

- [ ] **Step 3: 리포지토리 테스트**

`test/features/ledger/recurring_transaction_repository_test.dart` (기존 `calendar_event_repository_test.dart`와 동일한 `HttpServer` 패턴 — 특히 `next_run_at`이 로컬로 파싱되는지, `create`/`update`/`advanceNextRunAt`이 전부 UTC로 변환해 보내는지 명시적으로 검증):
```dart
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

  test('list parses next_run_at as local time, not UTC', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/recurring_transactions'));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'rt-1',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'created_by': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'interval_rule': 'MONTHLY',
          'next_run_at': '2026-09-06T21:00:00.000Z',
          'memo': null,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.nextRunAt.isUtc, isFalse);
  });

  test('create sends next_run_at converted to UTC', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      type: 'expense',
      amount: 50000,
      intervalRule: 'MONTHLY',
      nextRunAt: DateTime.parse('2026-09-06T06:00:00+09:00'),
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    final body = jsonDecode(bodyStr) as Map<String, dynamic>;
    expect(body['next_run_at'], '2026-09-05T21:00:00.000Z');
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'rt-2',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'created_by': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'interval_rule': 'MONTHLY',
          'next_run_at': '2026-09-05T21:00:00.000Z',
          'memo': null,
        },
      ]));
    await request.response.close();

    await future;
  });

  test('advanceNextRunAt only sends next_run_at, converted to UTC', () async {
    final future = repo.advanceNextRunAt('rt-1', DateTime.parse('2026-10-06T06:00:00+09:00'));

    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.rt-1');
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'next_run_at': '2026-10-05T21:00:00.000Z'});
    request.response.statusCode = HttpStatus.noContent;
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

- [ ] **Step 4: 테스트 실행**

Run: `flutter test test/features/ledger/recurring_transaction_repository_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/features/ledger/models/recurring_transaction.dart lib/features/ledger/recurring_transaction_repository.dart test/features/ledger/recurring_transaction_repository_test.dart
git commit -m "feat(ledger): add RecurringTransaction model and repository"
```

---

### Task 3: 다음 발생일 계산 순수 함수

**Files:**
- Create: `lib/features/ledger/recurring_transaction_schedule.dart`
- Test: `test/features/ledger/recurring_transaction_schedule_test.dart`

**Interfaces:**
- Produces: `const maxCatchUpOccurrences = 60;`, `DateTime advanceOccurrence(String intervalRule, DateTime from)`

이 함수는 캘린더의 `expandOccurrences`(범위 안의 모든 발생을 한 번에 계산 — 표시용)와 다르다. 이 함수는 "현재 발생 하나에서 다음 발생 하나로" 한 걸음만 계산하는 순수 함수이고, Task 4의 서비스가 이 함수를 반복 호출하며 매번 DB에 거래를 하나씩 쓰고 `next_run_at`을 그 자리에서 갱신한다(부분 실패 시 이미 처리한 만큼은 안전하게 보존하기 위해서 — 스펙 5번 참조).

- [ ] **Step 1: 계산 함수**

`lib/features/ledger/recurring_transaction_schedule.dart`:
```dart
const maxCatchUpOccurrences = 60;

const _weekdayCodes = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

/// Returns the next occurrence after [from] for [intervalRule]. Always
/// strictly after `from` (never equal), so repeated calls from a starting
/// point walk forward without repeating.
DateTime advanceOccurrence(String intervalRule, DateTime from) {
  if (intervalRule == 'DAILY') {
    return from.add(const Duration(days: 1));
  }

  if (intervalRule.startsWith('WEEKLY:')) {
    final days = intervalRule.substring(7).split(',').map((c) => _weekdayCodes[c]).whereType<int>().toSet();
    var next = from.add(const Duration(days: 1));
    if (days.isEmpty) return next; // malformed rule: degrade to daily rather than looping forever
    while (!days.contains(next.weekday)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }

  if (intervalRule == 'MONTHLY') {
    // Unlike the calendar's expandOccurrences (which SKIPS a month that
    // doesn't have the day-of-month, since it's just deciding what to
    // display), this rolls forward to the nearest valid date instead — see
    // the plan's Global Constraints for why: silently skipping a real
    // payment for a whole month is a worse surprise than charging it a few
    // days into the next month. DateTime's constructor does this rollover
    // on its own (e.g. day=31 in a 30-day month becomes the 1st of the
    // month after), so no extra guard is needed here.
    return DateTime(from.year, from.month + 1, from.day, from.hour, from.minute);
  }

  if (intervalRule == 'YEARLY') {
    return DateTime(from.year + 1, from.month, from.day, from.hour, from.minute);
  }

  // ponytail: unrecognized rule degrades to a daily step rather than looping
  // forever — interval_rule is only ever written by this app's own form
  // (always one of the 4 known shapes), so this path is unreachable in
  // normal use; it exists only so a caller looping on this function always
  // terminates.
  return from.add(const Duration(days: 1));
}
```

- [ ] **Step 2: 테스트**

`test/features/ledger/recurring_transaction_schedule_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_schedule.dart';

void main() {
  test('DAILY advances by exactly one day', () {
    final next = advanceOccurrence('DAILY', DateTime(2026, 9, 5, 10));
    expect(next, DateTime(2026, 9, 6, 10));
  });

  test('WEEKLY:MO,WE,FR advances to the next matching weekday', () {
    // 2026-09-07 is a Monday
    final next = advanceOccurrence('WEEKLY:MO,WE,FR', DateTime(2026, 9, 7, 8));
    expect(next.weekday, DateTime.wednesday);
    expect(next, DateTime(2026, 9, 9, 8));
  });

  test('WEEKLY with a single day wraps to the same weekday next week', () {
    final next = advanceOccurrence('WEEKLY:MO', DateTime(2026, 9, 7, 8)); // a Monday
    expect(next, DateTime(2026, 9, 14, 8));
  });

  test('MONTHLY advances to the same day next month', () {
    final next = advanceOccurrence('MONTHLY', DateTime(2026, 9, 15, 10));
    expect(next, DateTime(2026, 10, 15, 10));
  });

  test('MONTHLY rolls forward (does not skip) when the day does not exist in the next month', () {
    // Jan 31 -> Feb has no 31st -> rolls into March, unlike the calendar's skip behavior
    final next = advanceOccurrence('MONTHLY', DateTime(2026, 1, 31, 10));
    expect(next, DateTime(2026, 3, 3, 10));
  });

  test('YEARLY advances to the same month/day next year', () {
    final next = advanceOccurrence('YEARLY', DateTime(2026, 9, 15, 10));
    expect(next, DateTime(2027, 9, 15, 10));
  });

  test('an unrecognized rule degrades to a daily step instead of looping forever', () {
    final next = advanceOccurrence('GARBAGE', DateTime(2026, 9, 5, 10));
    expect(next, DateTime(2026, 9, 6, 10));
  });

  test('an empty WEEKLY rule degrades to a daily step instead of looping forever', () {
    final next = advanceOccurrence('WEEKLY:', DateTime(2026, 9, 5, 10));
    expect(next, DateTime(2026, 9, 6, 10));
  });

  test('maxCatchUpOccurrences is a sane positive cap', () {
    expect(maxCatchUpOccurrences, 60);
  });
}
```

- [ ] **Step 3: 테스트 실행**

Run: `flutter test test/features/ledger/recurring_transaction_schedule_test.dart`
Expected: PASS (9 tests)

- [ ] **Step 4: Commit**

```bash
git add lib/features/ledger/recurring_transaction_schedule.dart test/features/ledger/recurring_transaction_schedule_test.dart
git commit -m "feat(ledger): add advanceOccurrence pure function for recurring-transaction scheduling"
```

---

### Task 4: 소급 생성 서비스

**Files:**
- Modify: `lib/features/ledger/transaction_repository.dart` (`create()`에 선택적 `occurredAt` 파라미터 추가)
- Modify: `test/features/ledger/transaction_repository_test.dart` (새 파라미터 커버하는 테스트 추가)
- Create: `lib/features/ledger/recurring_transaction_catchup_service.dart`
- Test: `test/features/ledger/recurring_transaction_catchup_service_test.dart`

**Interfaces:**
- Consumes: `RecurringTransactionRepository`(Task 2), `advanceOccurrence`/`maxCatchUpOccurrences`(Task 3), `TransactionRepository.create(..., occurredAt:)`(이 태스크에서 확장)
- Produces: `RecurringTransactionCatchUpService` 클래스(의존성 주입 방식 — `notification_auto_save_service.dart`가 리포지토리들을 생성자로 받는 것과 동일한 패턴, 그래야 실제 `SupabaseClient`+로컬 `HttpServer`로 테스트 가능하다), 그리고 이 파일 상단에 선언되는 `recurringTransactionRepository`/`recurringTransactionCatchUpService` 최상위 인스턴스 — Task 5가 여기서 import해 재사용한다.

**주의 — 처음 초안은 전역 싱글턴을 서비스가 직접 참조하는 구조였다가, 이 태스크를 계획하며 `notification_auto_save_service.dart`를 실제로 읽어보고 고쳤다.** 그 파일의 서비스 클래스는 리포지토리를 생성자 파라미터로 받는다(전역 `supabase`를 내부에서 직접 참조하지 않음) — 그래야 테스트에서 실제 리포지토리 인스턴스를 로컬 `HttpServer`를 가리키게 만들어 통째로 주입할 수 있다. 이 프로젝트에 존재하는 유일한 "서비스가 여러 리포지토리를 조합" 전례이므로 그대로 따른다.

- [ ] **Step 1: `TransactionRepository.create()`에 `occurredAt` 파라미터 추가**

`lib/features/ledger/transaction_repository.dart`의 `create()` 시그니처와 본문을 아래처럼 수정한다 (기존 파라미터는 그대로 유지, `occurredAt` 하나만 추가):
```dart
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
      if (occurredAt != null) 'occurred_at': occurredAt.toUtc().toIso8601String(),
    }).select();
```
(`occurredAt`을 안 넘기면 `occurred_at` 키 자체를 payload에서 뺀다 — DB의 `default now()`가 그대로 적용된다. 기존 호출부는 전부 이 파라미터를 안 넘기므로 동작이 바뀌지 않는다.) 나머지 본문(태그 처리 등)은 그대로 둔다.

- [ ] **Step 2: 기존 테스트에 `occurredAt` 케이스 추가**

`test/features/ledger/transaction_repository_test.dart`의 `create` 관련 테스트들 아래에 새 테스트 하나 추가:
```dart
  test('create sends occurred_at converted to UTC when provided', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      memberId: 'member-1',
      type: 'expense',
      amount: 50000,
      source: 'recurring_auto',
      occurredAt: DateTime.parse('2026-09-06T06:00:00+09:00'),
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    final body = jsonDecode(bodyStr) as Map<String, dynamic>;
    expect(body['occurred_at'], '2026-09-05T21:00:00.000Z');
    expect(body['source'], 'recurring_auto');
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'txn-x',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'member_id': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'occurred_at': '2026-09-05T21:00:00.000Z',
          'source': 'recurring_auto',
          'memo': null,
          'merchant': null,
        },
      ]));
    await request.response.close();

    await future;
  });
```
(파일 상단에 이미 `dart:convert`/`dart:io` import가 있을 것 — 없다면 추가.)

- [ ] **Step 3: 테스트 실행 (Step 1-2)**

Run: `flutter test test/features/ledger/transaction_repository_test.dart`
Expected: PASS (기존 테스트 전부 + 신규 1개)

- [ ] **Step 4: 소급 생성 서비스**

`lib/features/ledger/recurring_transaction_catchup_service.dart`:
```dart
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

  /// Checks every due recurring-transaction template for [householdId] and
  /// creates the transactions it's behind on, one at a time — persisting
  /// `next_run_at` after each successful create so a failure partway
  /// through never loses progress or risks a duplicate on retry. Returns
  /// how many transactions were created (0 if nothing was due).
  ///
  /// [now] defaults to the real current time; tests pass a fixed value so
  /// the "is this due yet" cutoff is deterministic.
  Future<int> run(String householdId, {DateTime? now}) async {
    final cutoff = now ?? DateTime.now();
    final templates = await recurringTransactionRepository.list(householdId);
    var createdCount = 0;

    for (final template in templates) {
      var cursor = template.nextRunAt;
      var countForTemplate = 0;
      while (!cursor.isAfter(cutoff) && countForTemplate < maxCatchUpOccurrences) {
        await transactionRepository.create(
          householdId: householdId,
          accountId: template.accountId,
          categoryId: template.categoryId,
          memberId: template.createdBy,
          type: template.type,
          amount: template.amount,
          memo: template.memo,
          source: 'recurring_auto',
          occurredAt: cursor,
        );
        cursor = advanceOccurrence(template.intervalRule, cursor);
        await recurringTransactionRepository.advanceNextRunAt(template.id, cursor);
        createdCount++;
        countForTemplate++;
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

- [ ] **Step 5: 서비스 테스트**

`test/features/ledger/recurring_transaction_catchup_service_test.dart` — `RecurringTransactionCatchUpService`가 리포지토리를 생성자로 받으므로, `notification_auto_save_service_test.dart`와 동일하게 실제 리포지토리 인스턴스를 로컬 `HttpServer`를 가리키는 `SupabaseClient`로 만들어 그대로 주입한다. 첫 두 테스트는 요청 수가 적어(2~5건) 기존 `StreamIterator` 순차 검증 패턴을 그대로 쓰지만, 세 번째(상한 테스트)는 요청이 120개 이상 나가므로 하나하나 순차 검증하는 대신 `mockServer.listen(...)`으로 경로/메서드별 요청 수를 세는 방식을 쓴다 — 이건 이 프로젝트에서 처음 쓰는 패턴이라 아래 코드에 그대로 따라 작성한다.

```dart
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

  test('creates one transaction per overdue occurrence and advances next_run_at incrementally', () async {
    final requests = StreamIterator<HttpRequest>(mockServer);
    final future = service.run('household-1', now: DateTime.utc(2026, 8, 20));

    // 1: list recurring_transactions — one MONTHLY template last run 2026-07-15
    await requests.moveNext();
    final listRequest = requests.current;
    await listRequest.drain<void>();
    listRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'rt-1',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'created_by': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'interval_rule': 'MONTHLY',
          'next_run_at': DateTime.utc(2026, 7, 15).toIso8601String(),
          'memo': '월세',
        },
      ]));
    await listRequest.response.close();

    // 2: first overdue occurrence — creates the July transaction
    await requests.moveNext();
    final txn1Request = requests.current;
    expect(txn1Request.method, 'POST');
    expect(txn1Request.uri.path, endsWith('/transactions'));
    final txn1Body = jsonDecode(await utf8.decodeStream(txn1Request)) as Map<String, dynamic>;
    expect(txn1Body['occurred_at'], '2026-07-15T00:00:00.000Z');
    expect(txn1Body['source'], 'recurring_auto');
    txn1Request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'txn-1', 'account_id': 'account-1', 'category_id': 'category-1',
          'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
          'occurred_at': '2026-07-15T00:00:00.000Z', 'source': 'recurring_auto',
          'memo': '월세', 'merchant': null,
        },
      ]));
    await txn1Request.response.close();

    // 3: advance next_run_at to August right after the July occurrence succeeds
    await requests.moveNext();
    final patch1Request = requests.current;
    expect(patch1Request.method, 'PATCH');
    final patch1Body = jsonDecode(await utf8.decodeStream(patch1Request)) as Map<String, dynamic>;
    expect(patch1Body['next_run_at'], '2026-08-15T00:00:00.000Z');
    patch1Request.response.statusCode = HttpStatus.noContent;
    await patch1Request.response.close();

    // 4: second overdue occurrence — creates the August transaction
    await requests.moveNext();
    final txn2Request = requests.current;
    expect(txn2Request.method, 'POST');
    final txn2Body = jsonDecode(await utf8.decodeStream(txn2Request)) as Map<String, dynamic>;
    expect(txn2Body['occurred_at'], '2026-08-15T00:00:00.000Z');
    txn2Request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'txn-2', 'account_id': 'account-1', 'category_id': 'category-1',
          'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
          'occurred_at': '2026-08-15T00:00:00.000Z', 'source': 'recurring_auto',
          'memo': '월세', 'merchant': null,
        },
      ]));
    await txn2Request.response.close();

    // 5: advance next_run_at to September (now past `now`, so the loop stops there)
    await requests.moveNext();
    final patch2Request = requests.current;
    expect(patch2Request.method, 'PATCH');
    final patch2Body = jsonDecode(await utf8.decodeStream(patch2Request)) as Map<String, dynamic>;
    expect(patch2Body['next_run_at'], '2026-09-15T00:00:00.000Z');
    patch2Request.response.statusCode = HttpStatus.noContent;
    await patch2Request.response.close();

    expect(await future, 2);
    await requests.cancel();
  });

  test('a template that is not yet due creates nothing', () async {
    final requests = StreamIterator<HttpRequest>(mockServer);
    final future = service.run('household-1', now: DateTime.utc(2026, 8, 20));

    await requests.moveNext();
    final listRequest = requests.current;
    await listRequest.drain<void>();
    listRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'rt-1',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'created_by': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'interval_rule': 'MONTHLY',
          'next_run_at': DateTime.utc(2026, 10, 1).toIso8601String(),
          'memo': null,
        },
      ]));
    await listRequest.response.close();

    expect(await future, 0);
    await requests.cancel();
  });

  test('respects maxCatchUpOccurrences and leaves the remainder for next time', () async {
    // A DAILY template overdue since 2026-01-01, checked on 2026-12-31, is
    // hundreds of days behind — far more than the 60-occurrence cap. This
    // needs ~121 request/response round trips (1 list + 60×(create+advance)),
    // too many to script individually like the tests above — a generic
    // path-based auto-responder counts them instead.
    var postCount = 0;
    var patchCount = 0;
    DateTime? lastPatchedNextRunAt;

    mockServer.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/recurring_transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([
            {
              'id': 'rt-1',
              'account_id': 'account-1',
              'category_id': 'category-1',
              'created_by': 'member-1',
              'type': 'expense',
              'amount': 1000,
              'interval_rule': 'DAILY',
              'next_run_at': DateTime.utc(2026, 1, 1).toIso8601String(),
              'memo': null,
            },
          ]));
        await request.response.close();
      } else if (request.method == 'POST' && request.uri.path.endsWith('/transactions')) {
        postCount++;
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.created
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([
            {
              'id': 'txn-$postCount', 'account_id': 'account-1', 'category_id': 'category-1',
              'member_id': 'member-1', 'type': 'expense', 'amount': 1000,
              'occurred_at': DateTime.now().toUtc().toIso8601String(), 'source': 'recurring_auto',
              'memo': null, 'merchant': null,
            },
          ]));
        await request.response.close();
      } else if (request.method == 'PATCH' && request.uri.path.endsWith('/recurring_transactions')) {
        patchCount++;
        final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
        lastPatchedNextRunAt = DateTime.parse(body['next_run_at'] as String);
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      }
    });

    final count = await service.run('household-1', now: DateTime.utc(2026, 12, 31));

    expect(count, 60);
    expect(postCount, 60);
    expect(patchCount, 60);
    // Jan 1 + 59 days (the 60th created occurrence) = Mar 1; one more advance
    // past it (not created — the cap already tripped) lands on Mar 2, which
    // is what gets persisted as the template's new next_run_at.
    expect(lastPatchedNextRunAt, DateTime.utc(2026, 3, 2));
  });
}
```

- [ ] **Step 6: 테스트 실행**

Run: `flutter test test/features/ledger/recurring_transaction_catchup_service_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 7: Commit**

```bash
git add lib/features/ledger/transaction_repository.dart test/features/ledger/transaction_repository_test.dart lib/features/ledger/recurring_transaction_catchup_service.dart test/features/ledger/recurring_transaction_catchup_service_test.dart
git commit -m "feat(ledger): add recurring-transaction catch-up service"
```

---

### Task 5: 반복거래 관리 화면 + 홈 화면 연동

**Files:**
- Create: `lib/features/ledger/recurring_transaction_screen.dart`
- Modify: `lib/features/household/home_screen.dart`

**Interfaces:**
- Consumes: `recurringTransactionRepository`/`recurringTransactionCatchUpService`(Task 4), `RecurringTransaction`(Task 2), `accountRepository`/`categoryRepository`(기존, `account_screen.dart`/`category_screen.dart`에서 import)

- [ ] **Step 1: 관리 화면**

`lib/features/ledger/recurring_transaction_screen.dart` — 목록+작성/수정 폼을 한 화면에서 처리 (카테고리 관리 화면과 같은 목록+인라인 폼 패턴이 아니라, 계좌/카테고리/주기 규칙까지 다뤄야 해서 캘린더의 `calendar_event_form_screen.dart`처럼 목록 화면 + 별도 폼 화면 두 개로 나눈다):

`lib/features/ledger/recurring_transaction_screen.dart`에 두 위젯을 함께 정의한다.

```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/models/account.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart' show recurringTransactionRepository;

class RecurringTransactionListScreen extends StatefulWidget {
  const RecurringTransactionListScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<RecurringTransactionListScreen> createState() => _RecurringTransactionListScreenState();
}

class _RecurringTransactionListScreenState extends State<RecurringTransactionListScreen> {
  List<RecurringTransaction>? _templates;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final templates = await recurringTransactionRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _templates = templates;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '반복거래를 불러오지 못했어요');
    }
  }

  String _ruleLabel(String rule) {
    if (rule == 'DAILY') return '매일';
    if (rule.startsWith('WEEKLY:')) return '매주';
    if (rule == 'MONTHLY') return '매월';
    if (rule == 'YEARLY') return '매년';
    return rule;
  }

  @override
  Widget build(BuildContext context) {
    final templates = _templates;
    return Scaffold(
      appBar: AppBar(title: const Text('반복거래 관리')),
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
                            subtitle: Text('다음 실행: ${t.nextRunAt.year}-${t.nextRunAt.month.toString().padLeft(2, '0')}-${t.nextRunAt.day.toString().padLeft(2, '0')}'),
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
}

const _weekdayLabels = [
  ('MO', '월'), ('TU', '화'), ('WE', '수'), ('TH', '목'), ('FR', '금'), ('SA', '토'), ('SU', '일'),
];

enum _Frequency { daily, weekly, monthly, yearly }

class RecurringTransactionFormScreen extends StatefulWidget {
  const RecurringTransactionFormScreen({super.key, required this.householdId, this.existing});

  final String householdId;
  final RecurringTransaction? existing;

  @override
  State<RecurringTransactionFormScreen> createState() => _RecurringTransactionFormScreenState();
}

class _RecurringTransactionFormScreenState extends State<RecurringTransactionFormScreen> {
  late final _amountController = TextEditingController(text: widget.existing?.amount.toString() ?? '');
  late final _memoController = TextEditingController(text: widget.existing?.memo ?? '');
  late String _type = widget.existing?.type ?? 'expense';
  late DateTime _nextRunAt = widget.existing?.nextRunAt ?? DateTime.now();
  late _Frequency _frequency = _parseFrequency(widget.existing?.intervalRule);
  late final Set<String> _selectedWeekdays = _parseWeekdays(widget.existing?.intervalRule);
  List<Account>? _accounts;
  List<Category>? _categories;
  String? _accountId = null;
  String? _categoryId = null;
  String? _error;
  bool _saving = false;

  static _Frequency _parseFrequency(String? rule) {
    if (rule == 'DAILY') return _Frequency.daily;
    if (rule != null && rule.startsWith('WEEKLY:')) return _Frequency.weekly;
    if (rule == 'YEARLY') return _Frequency.yearly;
    return _Frequency.monthly;
  }

  static Set<String> _parseWeekdays(String? rule) {
    if (rule == null || !rule.startsWith('WEEKLY:')) return {};
    return rule.substring(7).split(',').toSet();
  }

  String get _intervalRule {
    switch (_frequency) {
      case _Frequency.daily:
        return 'DAILY';
      case _Frequency.weekly:
        return _selectedWeekdays.isEmpty ? 'DAILY' : 'WEEKLY:${_selectedWeekdays.join(',')}';
      case _Frequency.monthly:
        return 'MONTHLY';
      case _Frequency.yearly:
        return 'YEARLY';
    }
  }

  @override
  void initState() {
    super.initState();
    _accountId = widget.existing?.accountId;
    _categoryId = widget.existing?.categoryId;
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final requestedType = _type;
    try {
      final accounts = await accountRepository.list(widget.householdId);
      final categories = await categoryRepository.list(widget.householdId, type: _type);
      if (!mounted || requestedType != _type) return;
      setState(() {
        _accounts = accounts;
        _categories = categories;
        _accountId = accounts.any((a) => a.id == _accountId) ? _accountId : (accounts.isNotEmpty ? accounts.first.id : null);
        _categoryId = categories.any((c) => c.id == _categoryId) ? _categoryId : (categories.isNotEmpty ? categories.first.id : null);
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestedType != _type) return;
      setState(() => _error = '계좌/카테고리를 불러오지 못했어요');
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _nextRunAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _nextRunAt = DateTime(picked.year, picked.month, picked.day, _nextRunAt.hour, _nextRunAt.minute));
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amountController.text.trim());
    final accountId = _accountId;
    final categoryId = _categoryId;
    if (amount == null || amount <= 0 || accountId == null || categoryId == null) {
      setState(() => _error = '금액, 계좌, 카테고리를 확인해주세요');
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
        final memberRow = await supabase
            .from('household_members')
            .select('id')
            .eq('household_id', widget.householdId)
            .eq('user_id', supabase.auth.currentUser!.id)
            .single();
        await recurringTransactionRepository.create(
          householdId: widget.householdId,
          accountId: accountId,
          categoryId: categoryId,
          createdBy: memberRow['id'] as String,
          type: _type,
          amount: amount,
          intervalRule: _intervalRule,
          nextRunAt: _nextRunAt,
          memo: memo,
        );
      } else {
        await recurringTransactionRepository.update(
          id: existing.id,
          accountId: accountId,
          categoryId: categoryId,
          type: _type,
          amount: amount,
          intervalRule: _intervalRule,
          nextRunAt: _nextRunAt,
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

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('반복거래 삭제'),
        content: const Text('템플릿만 삭제되고, 이미 생성된 과거 거래는 그대로 남아있어요. 삭제할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('삭제')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await recurringTransactionRepository.delete(existing.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '반복거래 삭제에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final categories = _categories;
    final existing = widget.existing;
    if (accounts == null || categories == null) {
      return Scaffold(
        appBar: AppBar(title: Text(existing == null ? '반복거래 추가' : '반복거래 수정')),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
            : const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? '반복거래 추가' : '반복거래 수정'),
        actions: [
          if (existing != null)
            IconButton(icon: const Icon(Icons.delete), onPressed: _saving ? null : _delete),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
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
            if (accounts.isNotEmpty)
              DropdownButton<String>(
                value: _accountId,
                items: accounts.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name))).toList(),
                onChanged: (v) => setState(() => _accountId = v),
              ),
            if (categories.isNotEmpty)
              DropdownButton<String>(
                value: _categoryId,
                items: categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            TextField(
              controller: _memoController,
              decoration: const InputDecoration(labelText: '메모(선택)'),
            ),
            ListTile(
              title: const Text('시작일(다음 실행일)'),
              subtitle: Text('${_nextRunAt.year}-${_nextRunAt.month.toString().padLeft(2, '0')}-${_nextRunAt.day.toString().padLeft(2, '0')}'),
              onTap: _pickDate,
            ),
            DropdownButton<_Frequency>(
              value: _frequency,
              items: const [
                DropdownMenuItem(value: _Frequency.daily, child: Text('매일')),
                DropdownMenuItem(value: _Frequency.weekly, child: Text('매주')),
                DropdownMenuItem(value: _Frequency.monthly, child: Text('매월')),
                DropdownMenuItem(value: _Frequency.yearly, child: Text('매년')),
              ],
              onChanged: (v) => setState(() => _frequency = v ?? _Frequency.monthly),
            ),
            if (_frequency == _Frequency.weekly)
              Wrap(
                spacing: 8,
                children: _weekdayLabels.map((entry) {
                  final (code, label) = entry;
                  final selected = _selectedWeekdays.contains(code);
                  return FilterChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedWeekdays.add(code);
                      } else {
                        _selectedWeekdays.remove(code);
                      }
                    }),
                  );
                }).toList(),
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

- [ ] **Step 2: 홈 화면에 메뉴 + 소급 생성 트리거 추가**

`home_screen.dart` import에 추가:
```dart
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart' show recurringTransactionCatchUpService;
import 'package:ppyu_budget/features/ledger/recurring_transaction_screen.dart';
```

`_loadHousehold()`를 아래처럼 수정 — household가 있을 때만, 로드 성공 후 조용히 소급 생성을 체크하고 생성된 게 있으면 스낵바로 알림:
```dart
  Future<void> _loadHousehold() async {
    final householdId = await _repository.getMyHousehold();
    if (!mounted) return;
    setState(() {
      _householdId = householdId;
      _loading = false;
      _recommendationsFuture = householdId != null ? _fetchRecommendations(householdId) : null;
    });
    if (householdId != null) {
      _runCatchUp(householdId);
    }
  }

  Future<void> _runCatchUp(String householdId) async {
    try {
      final count = await recurringTransactionCatchUpService.run(householdId);
      if (!mounted || count == 0) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count건의 반복거래가 등록됐어요')),
      );
    } catch (_) {
      // 조용히 무시 — 다음 홈 화면 진입 때 다시 시도된다.
    }
  }
```
(스펙 3-6 참조: 실패해도 홈 화면 진입 자체를 막지 않는다 — `_loadHousehold()`의 기존 `setState` 흐름과 별개로, `await` 없이 fire-and-forget으로 호출한다.)

`ListTile` 목록에 추가 (이번 달 예산 항목 근처):
```dart
            ListTile(
              title: const Text('반복거래 관리'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RecurringTransactionListScreen(householdId: householdId),
              )),
            ),
```

- [ ] **Step 3: 수동 확인**

Run: `flutter analyze`
Expected: 새 에러 없음

- [ ] **Step 4: Commit**

```bash
git add lib/features/ledger/recurring_transaction_screen.dart lib/features/household/home_screen.dart
git commit -m "feat(ledger): add recurring transaction management screen and home-screen catch-up trigger"
```
