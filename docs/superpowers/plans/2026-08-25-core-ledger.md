# Core Ledger (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a household manage accounts/cards, categories, manually-entered transactions, monthly budgets, and savings goals — the "기본 가계부 사용 가능" milestone from the spec.

**Architecture:** Unlike Phase 1 (foundation), which routed every household-linking mutation through Postgres RPCs, ledger data is high-volume CRUD with flexible filtering (by date, category, account). It uses **direct RLS-scoped table access** instead: the client calls `.from('transactions').select()/.insert()/.update()/.delete()` etc. directly, and Postgres Row Level Security — driven by a shared `is_household_member(household_id)` helper function — is the only thing standing between a request and the data. No new RPCs are added in this phase except widening `create_household_and_owner()` to seed default categories.

**Tech Stack:** Same as Phase 1 (Flutter, Supabase/Postgres+RLS). No new packages needed.

**Spec:** [docs/superpowers/specs/2026-08-25-ppyu-gagyebu-design.md](../specs/2026-08-25-ppyu-gagyebu-design.md)

## Global Constraints

- Platform: Android only (unchanged from Phase 1).
- No SMS auto-entry, no bank/card API integration in this phase — every transaction is entered by hand. (SMS parsing is Phase 3; there is no "Phase for API integration" — it's out of MVP scope entirely per the spec.)
- Currency: KRW only, whole-won amounts (no decimal subunits) — store amounts as Postgres `integer`, not `numeric`, to avoid JSON-number/float ambiguity.
- Every new table gets Row Level Security enabled; every `SECURITY DEFINER` function gets `set search_path = public, pg_temp` and `revoke execute on function ... from public, anon` (established in Phase 1's final review — do not skip this on new functions).
- One shared ledger per household (no per-member wallets) — every table is scoped by `household_id`, not by individual member, matching spec section 6 decision #1.
- Repository tests that call `.from(...)`/`.rpc(...)` must use the real-`SupabaseClient`-against-local-`HttpServer` pattern established in `ppyu_budget/test/features/household/household_repository_test.dart` — **do not** attempt to mock `SupabaseClient` directly with `mocktail`; `PostgrestFilterBuilder<T>` implements but is not literally `Future<T>`, so that pattern doesn't compile (this bit Task 4 and Task 6 of Phase 1's plan).
- Widget tests that need to control a repository's return value without touching the network should use a lightweight fake subclass (see `ppyu_budget/test/features/household/home_screen_test.dart`'s `_FakeHouseholdRepository` pattern), not a mock.
- Run both `flutter test` and `flutter analyze` for every task, with raw (not paraphrased) output in the report — a `flutter test`-only check missed a real compile error in Phase 1.

---

### Task 1: Ledger schema, RLS, and default category seeding

**Files:**
- Create: `ppyu_budget/supabase/migrations/0003_ledger_schema.sql`
- Create: `ppyu_budget/supabase/tests/0003_ledger_schema_test.sql`

**Interfaces:**
- Produces: tables `accounts`, `categories`, `transactions`, `budgets`, `savings_goals` (all household-scoped, RLS-protected); function `is_household_member(p_household_id uuid) returns boolean` (reusable in later migrations too); `create_household_and_owner()` is widened (via `create or replace function`) to seed default categories after creating the household.

- [ ] **Step 1: Write the migration**

`ppyu_budget/supabase/migrations/0003_ledger_schema.sql`:
```sql
create or replace function is_household_member(p_household_id uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = auth.uid() and left_at is null
  );
$$;
revoke execute on function is_household_member(uuid) from public, anon;

create table accounts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  owner_member_id uuid references household_members(id) on delete set null,
  name text not null,
  type text not null default 'card' check (type in ('card', 'bank', 'cash')),
  created_at timestamptz not null default now()
);

create table categories (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name text not null,
  icon text,
  type text not null default 'expense' check (type in ('income', 'expense')),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create table transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete restrict,
  category_id uuid not null references categories(id) on delete restrict,
  member_id uuid not null references household_members(id) on delete restrict,
  type text not null check (type in ('income', 'expense')),
  amount integer not null check (amount > 0),
  memo text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table budgets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  category_id uuid references categories(id) on delete cascade,
  month date not null,
  amount integer not null check (amount >= 0),
  unique (household_id, category_id, month)
);
-- the composite unique constraint above doesn't stop two "overall" (null
-- category_id) budgets in the same month, since SQL unique constraints treat
-- NULL as distinct from every other NULL — this partial index closes that gap.
create unique index budgets_household_month_overall_unique
  on budgets (household_id, month) where category_id is null;

create table savings_goals (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name text not null,
  target_amount integer not null check (target_amount > 0),
  current_amount integer not null default 0 check (current_amount >= 0),
  target_date date,
  created_at timestamptz not null default now()
);

alter table accounts enable row level security;
alter table categories enable row level security;
alter table transactions enable row level security;
alter table budgets enable row level security;
alter table savings_goals enable row level security;

create policy "members can select accounts" on accounts for select using (is_household_member(household_id));
create policy "members can insert accounts" on accounts for insert with check (is_household_member(household_id));
create policy "members can update accounts" on accounts for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete accounts" on accounts for delete using (is_household_member(household_id));

create policy "members can select categories" on categories for select using (is_household_member(household_id));
create policy "members can insert categories" on categories for insert with check (is_household_member(household_id));
create policy "members can update categories" on categories for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete categories" on categories for delete using (is_household_member(household_id));

create policy "members can select transactions" on transactions for select using (is_household_member(household_id));
create policy "members can insert transactions" on transactions for insert with check (is_household_member(household_id));
create policy "members can update transactions" on transactions for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete transactions" on transactions for delete using (is_household_member(household_id));

create policy "members can select budgets" on budgets for select using (is_household_member(household_id));
create policy "members can insert budgets" on budgets for insert with check (is_household_member(household_id));
create policy "members can update budgets" on budgets for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete budgets" on budgets for delete using (is_household_member(household_id));

create policy "members can select savings goals" on savings_goals for select using (is_household_member(household_id));
create policy "members can insert savings goals" on savings_goals for insert with check (is_household_member(household_id));
create policy "members can update savings goals" on savings_goals for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete savings goals" on savings_goals for delete using (is_household_member(household_id));

-- widen create_household_and_owner (from 0002) to seed default categories
create or replace function create_household_and_owner()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_household_id uuid;
begin
  if get_my_household() is not null then
    raise exception 'already_in_household';
  end if;

  insert into households default values returning id into new_household_id;
  begin
    insert into household_members (household_id, user_id, role)
    values (new_household_id, auth.uid(), 'owner');
  exception when unique_violation then
    raise exception 'already_in_household';
  end;

  insert into categories (household_id, name, type, is_default) values
    (new_household_id, '식비', 'expense', true),
    (new_household_id, '교통비', 'expense', true),
    (new_household_id, '주거/공과금', 'expense', true),
    (new_household_id, '생활/쇼핑', 'expense', true),
    (new_household_id, '문화/여가', 'expense', true),
    (new_household_id, '의료/건강', 'expense', true),
    (new_household_id, '기타', 'expense', true),
    (new_household_id, '급여', 'income', true),
    (new_household_id, '용돈', 'income', true),
    (new_household_id, '기타수입', 'income', true);

  return new_household_id;
end;
$$;
```

- [ ] **Step 2: Push the migration to the linked remote project**

Run (from `ppyu_budget/`): `npx -y supabase db push`
Expected: `"upToDate":false` on first run, migration applied.

- [ ] **Step 3: Write the SQL test**

`ppyu_budget/supabase/tests/0003_ledger_schema_test.sql`:
```sql
-- Run with: supabase db query --linked --file supabase/tests/0003_ledger_schema_test.sql
begin;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999999', 'z@test.com')
  on conflict do nothing;

-- default categories are seeded on household creation
savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_count int;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();

  select count(*) into v_count from categories where household_id = v_household_id;
  if v_count != 10 then
    raise exception 'TEST FAILED: expected 10 default categories, got %', v_count;
  end if;
end $$;
rollback to savepoint sp1;

-- a non-member cannot see or insert into another household's accounts (RLS)
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_account_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  insert into accounts (household_id, name) values (v_household_id, '현금')
    returning id into v_account_id;

  perform set_config('request.jwt.claims', '{"sub":"99999999-9999-9999-9999-999999999999"}', true);
  if exists (select 1 from accounts where id = v_account_id) then
    raise exception 'TEST FAILED: a non-member could see another household''s account';
  end if;

  begin
    insert into accounts (household_id, name) values (v_household_id, 'hijacked');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a non-member inserted an account into another household';
  end if;
end $$;
rollback to savepoint sp2;

-- a member can create a transaction referencing their own household's account/category
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_category_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  select id into v_account_id from accounts where household_id = v_household_id limit 1;
  if v_account_id is null then
    insert into accounts (household_id, name) values (v_household_id, '현금') returning id into v_account_id;
  end if;
  select id into v_category_id from categories where household_id = v_household_id and type = 'expense' limit 1;

  insert into transactions (household_id, account_id, category_id, member_id, type, amount, memo)
  values (v_household_id, v_account_id, v_category_id, v_member_id, 'expense', 12000, '점심');

  if (select count(*) from transactions where household_id = v_household_id) != 1 then
    raise exception 'TEST FAILED: transaction was not inserted';
  end if;
end $$;
rollback to savepoint sp3;

-- only one "overall" (null category_id) budget per household per month
savepoint sp4;
do $$
declare
  v_household_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();

  insert into budgets (household_id, category_id, month, amount) values (v_household_id, null, '2026-09-01', 1000000);
  begin
    insert into budgets (household_id, category_id, month, amount) values (v_household_id, null, '2026-09-01', 2000000);
  exception when unique_violation then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: a second overall budget for the same household/month was allowed';
  end if;
end $$;
rollback to savepoint sp4;

rollback;
```

- [ ] **Step 4: Run the test**

Run: `npx -y supabase db query --linked --file supabase/tests/0003_ledger_schema_test.sql`
Expected: no `TEST FAILED`, no unhandled error.

- [ ] **Step 5: Commit**

```bash
git add ppyu_budget/supabase/migrations/0003_ledger_schema.sql ppyu_budget/supabase/tests/0003_ledger_schema_test.sql
git commit -m "feat: add ledger schema (accounts, categories, transactions, budgets, savings goals) with RLS"
```

---

### Task 2: Account model + repository + screen

**Files:**
- Create: `ppyu_budget/lib/features/ledger/models/account.dart`
- Create: `ppyu_budget/lib/features/ledger/account_repository.dart`
- Create: `ppyu_budget/lib/features/ledger/account_screen.dart`
- Test: `ppyu_budget/test/features/ledger/account_repository_test.dart`

**Interfaces:**
- Consumes: `supabase` getter (`core/supabase_client.dart`).
- Produces: `class Account { id, name, type }` with `Account.fromJson`; `class AccountRepository { Future<List<Account>> list(String householdId); Future<Account> create(String householdId, String name, String type); }` — Task 4/5 (transactions) need `AccountRepository.list` to populate a picker.

- [ ] **Step 1: Write the model**

`ppyu_budget/lib/features/ledger/models/account.dart`:
```dart
class Account {
  const Account({required this.id, required this.name, required this.type});

  final String id;
  final String name;
  final String type;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
      );
}
```

- [ ] **Step 2: Write the failing repository test**

`ppyu_budget/test/features/ledger/account_repository_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/account_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late AccountRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = AccountRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches accounts for a household', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/accounts'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'a1', 'name': '신한카드', 'type': 'card'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '신한카드');
  });

  test('create posts a new account and returns it', () async {
    final future = repo.create('household-1', '현금', 'cash');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/accounts'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'name': '현금',
      'type': 'cash',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'a2', 'name': '현금', 'type': 'cash'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '현금');
    expect(result.type, 'cash');
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ledger/account_repository_test.dart`
Expected: FAIL — `AccountRepository` doesn't exist.

- [ ] **Step 4: Implement the repository**

`ppyu_budget/lib/features/ledger/account_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/account.dart';

class AccountRepository {
  AccountRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Account>> list(String householdId) async {
    final rows = await _client
        .from('accounts')
        .select()
        .eq('household_id', householdId);
    return rows.map(Account.fromJson).toList();
  }

  Future<Account> create(String householdId, String name, String type) async {
    final rows = await _client.from('accounts').insert({
      'household_id': householdId,
      'name': name,
      'type': type,
    }).select();
    return Account.fromJson(rows.first);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/ledger/account_repository_test.dart`
Expected: PASS

- [ ] **Step 6: Build the account screen**

`ppyu_budget/lib/features/ledger/account_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/account_repository.dart';
import 'package:ppyu_budget/features/ledger/models/account.dart';

final accountRepository = AccountRepository(client: supabase);

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.householdId, AccountRepository? repository})
      : _repository = repository;

  final String householdId;
  final AccountRepository? _repository;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final AccountRepository _repository = widget._repository ?? accountRepository;
  final _nameController = TextEditingController();
  String _type = 'card';
  List<Account>? _accounts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final accounts = await _repository.list(widget.householdId);
      if (!mounted) return;
      setState(() => _accounts = accounts);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '계좌 목록을 불러오지 못했어요');
    }
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    try {
      await _repository.create(widget.householdId, name, _type);
      _nameController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '계좌 추가에 실패했어요');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    return Scaffold(
      appBar: AppBar(title: const Text('계좌/카드 관리')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: accounts == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: accounts.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(accounts[i].name),
                      subtitle: Text(accounts[i].type),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: '계좌/카드 이름'),
                  ),
                ),
                DropdownButton<String>(
                  value: _type,
                  items: const [
                    DropdownMenuItem(value: 'card', child: Text('카드')),
                    DropdownMenuItem(value: 'bank', child: Text('계좌')),
                    DropdownMenuItem(value: 'cash', child: Text('현금')),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'card'),
                ),
                IconButton(icon: const Icon(Icons.add), onPressed: _add),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 7: Run the full test suite**

Run: `flutter test` AND `flutter analyze`
Expected: PASS, no new analyze errors.

- [ ] **Step 8: Commit**

```bash
git add ppyu_budget/lib/features/ledger/models/account.dart ppyu_budget/lib/features/ledger/account_repository.dart \
        ppyu_budget/lib/features/ledger/account_screen.dart ppyu_budget/test/features/ledger/account_repository_test.dart
git commit -m "feat: add account model, repository, and management screen"
```

---

### Task 3: Category model + repository + screen

**Files:**
- Create: `ppyu_budget/lib/features/ledger/models/category.dart`
- Create: `ppyu_budget/lib/features/ledger/category_repository.dart`
- Create: `ppyu_budget/lib/features/ledger/category_screen.dart`
- Test: `ppyu_budget/test/features/ledger/category_repository_test.dart`

**Interfaces:**
- Consumes: `supabase` getter.
- Produces: `class Category { id, name, icon, type, isDefault }`; `class CategoryRepository { Future<List<Category>> list(String householdId, {String? type}); Future<Category> create(String householdId, String name, String type); }` — Task 5 (transaction form) and Task 6 (budgets) need `CategoryRepository.list`.

- [ ] **Step 1: Write the model**

`ppyu_budget/lib/features/ledger/models/category.dart`:
```dart
class Category {
  const Category({
    required this.id,
    required this.name,
    required this.type,
    this.icon,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final String type;
  final String? icon;
  final bool isDefault;

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        icon: json['icon'] as String?,
        isDefault: json['is_default'] as bool? ?? false,
      );
}
```

- [ ] **Step 2: Write the failing repository test**

`ppyu_budget/test/features/ledger/category_repository_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late CategoryRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = CategoryRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches categories for a household filtered by type', () async {
    final future = repo.list('household-1', type: 'expense');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/categories'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    expect(request.uri.queryParameters['type'], 'eq.expense');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'c1', 'name': '식비', 'type': 'expense', 'icon': null, 'is_default': true},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '식비');
    expect(result.first.isDefault, isTrue);
  });

  test('create posts a new custom category', () async {
    final future = repo.create('household-1', '반려동물', 'expense');

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'name': '반려동물',
      'type': 'expense',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'c2', 'name': '반려동물', 'type': 'expense', 'icon': null, 'is_default': false},
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '반려동물');
    expect(result.isDefault, isFalse);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ledger/category_repository_test.dart`
Expected: FAIL — `CategoryRepository` doesn't exist.

- [ ] **Step 4: Implement the repository**

`ppyu_budget/lib/features/ledger/category_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';

class CategoryRepository {
  CategoryRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Category>> list(String householdId, {String? type}) async {
    var query = _client.from('categories').select().eq('household_id', householdId);
    if (type != null) {
      query = query.eq('type', type);
    }
    final rows = await query;
    return rows.map(Category.fromJson).toList();
  }

  Future<Category> create(String householdId, String name, String type) async {
    final rows = await _client.from('categories').insert({
      'household_id': householdId,
      'name': name,
      'type': type,
    }).select();
    return Category.fromJson(rows.first);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/ledger/category_repository_test.dart`
Expected: PASS

- [ ] **Step 6: Build the category screen**

`ppyu_budget/lib/features/ledger/category_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';

final categoryRepository = CategoryRepository(client: supabase);

class CategoryScreen extends StatefulWidget {
  const CategoryScreen({super.key, required this.householdId, CategoryRepository? repository})
      : _repository = repository;

  final String householdId;
  final CategoryRepository? _repository;

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  late final CategoryRepository _repository = widget._repository ?? categoryRepository;
  final _nameController = TextEditingController();
  String _type = 'expense';
  List<Category>? _categories;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final categories = await _repository.list(widget.householdId);
      if (!mounted) return;
      setState(() => _categories = categories);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '카테고리를 불러오지 못했어요');
    }
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    try {
      await _repository.create(widget.householdId, name, _type);
      _nameController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '카테고리 추가에 실패했어요');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    return Scaffold(
      appBar: AppBar(title: const Text('카테고리 관리')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: categories == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: categories.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(categories[i].name),
                      subtitle: Text(categories[i].type == 'expense' ? '지출' : '수입'),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: '새 카테고리'),
                  ),
                ),
                DropdownButton<String>(
                  value: _type,
                  items: const [
                    DropdownMenuItem(value: 'expense', child: Text('지출')),
                    DropdownMenuItem(value: 'income', child: Text('수입')),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'expense'),
                ),
                IconButton(icon: const Icon(Icons.add), onPressed: _add),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 7: Run the full test suite**

Run: `flutter test` AND `flutter analyze`

- [ ] **Step 8: Commit**

```bash
git add ppyu_budget/lib/features/ledger/models/category.dart ppyu_budget/lib/features/ledger/category_repository.dart \
        ppyu_budget/lib/features/ledger/category_screen.dart ppyu_budget/test/features/ledger/category_repository_test.dart
git commit -m "feat: add category model, repository, and management screen"
```

---

### Task 4: Transaction model + repository

**Files:**
- Create: `ppyu_budget/lib/features/ledger/models/transaction.dart`
- Create: `ppyu_budget/lib/features/ledger/transaction_repository.dart`
- Test: `ppyu_budget/test/features/ledger/transaction_repository_test.dart`

**Interfaces:**
- Consumes: `supabase` getter.
- Produces: `class LedgerTransaction { id, accountId, categoryId, memberId, type, amount, memo, occurredAt }`; `class TransactionRepository { Future<List<LedgerTransaction>> list(String householdId); Future<LedgerTransaction> create({required String householdId, required String accountId, required String categoryId, required String memberId, required String type, required int amount, String? memo}); Future<void> delete(String id); }` — Task 5 (screens) depends on this.

Note: the class is named `LedgerTransaction`, not `Transaction` — `Transaction` collides with `dart:async`'s `Zone`-related `Transaction`-adjacent naming in some contexts and, more importantly, is a generic enough name to shadow confusingly; keep the more specific name.

- [ ] **Step 1: Write the model**

`ppyu_budget/lib/features/ledger/models/transaction.dart`:
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
    this.memo,
  });

  final String id;
  final String accountId;
  final String categoryId;
  final String memberId;
  final String type;
  final int amount;
  final DateTime occurredAt;
  final String? memo;

  factory LedgerTransaction.fromJson(Map<String, dynamic> json) => LedgerTransaction(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        categoryId: json['category_id'] as String,
        memberId: json['member_id'] as String,
        type: json['type'] as String,
        amount: json['amount'] as int,
        occurredAt: DateTime.parse(json['occurred_at'] as String),
        memo: json['memo'] as String?,
      );
}
```

- [ ] **Step 2: Write the failing repository test**

`ppyu_budget/test/features/ledger/transaction_repository_test.dart`:
```dart
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

  test('list fetches a household\'s transactions', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/transactions'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't1',
          'account_id': 'a1',
          'category_id': 'c1',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 12000,
          'occurred_at': '2026-08-25T12:00:00Z',
          'memo': '점심',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.amount, 12000);
    expect(result.first.memo, '점심');
  });

  test('create posts a new transaction', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'a1',
      categoryId: 'c1',
      memberId: 'm1',
      type: 'expense',
      amount: 5000,
      memo: '커피',
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
      'memo': '커피',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't2',
          'account_id': 'a1',
          'category_id': 'c1',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 5000,
          'occurred_at': '2026-08-25T13:00:00Z',
          'memo': '커피',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.amount, 5000);
  });

  test('delete removes a transaction by id', () async {
    final future = repo.delete('t1');

    final request = await mockServer.first;
    expect(request.method, 'DELETE');
    expect(request.uri.path, endsWith('/transactions'));
    expect(request.uri.queryParameters['id'], 'eq.t1');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ledger/transaction_repository_test.dart`
Expected: FAIL — `TransactionRepository` doesn't exist.

- [ ] **Step 4: Implement the repository**

`ppyu_budget/lib/features/ledger/transaction_repository.dart`:
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
  }) async {
    final rows = await _client.from('transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'member_id': memberId,
      'type': type,
      'amount': amount,
      'memo': memo,
    }).select();
    return LedgerTransaction.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('transactions').delete().eq('id', id);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/ledger/transaction_repository_test.dart`
Expected: PASS

- [ ] **Step 6: Run the full test suite**

Run: `flutter test` AND `flutter analyze`

- [ ] **Step 7: Commit**

```bash
git add ppyu_budget/lib/features/ledger/models/transaction.dart ppyu_budget/lib/features/ledger/transaction_repository.dart \
        ppyu_budget/test/features/ledger/transaction_repository_test.dart
git commit -m "feat: add transaction model and repository"
```

---

### Task 5: Transaction list + add screens

**Files:**
- Create: `ppyu_budget/lib/features/ledger/transaction_list_screen.dart`
- Create: `ppyu_budget/lib/features/ledger/transaction_form_screen.dart`

**Interfaces:**
- Consumes: `TransactionRepository`, `AccountRepository`, `CategoryRepository` (Tasks 2-4).
- Produces: nothing consumed by later tasks in this plan directly — Task 8 (ledger home) navigates here.

- [ ] **Step 1: Build the add/edit form screen**

`ppyu_budget/lib/features/ledger/transaction_form_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/account_repository.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/models/account.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

final transactionRepository = TransactionRepository(client: supabase);

class TransactionFormScreen extends StatefulWidget {
  const TransactionFormScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends State<TransactionFormScreen> {
  final _amountController = TextEditingController();
  final _memoController = TextEditingController();
  String _type = 'expense';
  List<Account>? _accounts;
  List<Category>? _categories;
  String? _accountId;
  String? _categoryId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final accounts = await accountRepository.list(widget.householdId);
    final categories = await categoryRepository.list(widget.householdId, type: _type);
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _categories = categories;
      _accountId = accounts.isNotEmpty ? accounts.first.id : null;
      _categoryId = categories.isNotEmpty ? categories.first.id : null;
    });
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
      final memberRow = await supabase
          .from('household_members')
          .select('id')
          .eq('household_id', widget.householdId)
          .eq('user_id', supabase.auth.currentUser!.id)
          .single();
      await transactionRepository.create(
        householdId: widget.householdId,
        accountId: accountId,
        categoryId: categoryId,
        memberId: memberRow['id'] as String,
        type: _type,
        amount: amount,
        memo: _memoController.text.trim().isEmpty ? null : _memoController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 저장에 실패했어요');
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
    if (accounts == null || categories == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('거래 추가')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
                items: accounts
                    .map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
                    .toList(),
                onChanged: (v) => setState(() => _accountId = v),
              ),
            if (categories.isNotEmpty)
              DropdownButton<String>(
                value: _categoryId,
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

- [ ] **Step 2: Build the list screen**

`ppyu_budget/lib/features/ledger/transaction_list_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart';

class TransactionListScreen extends StatefulWidget {
  const TransactionListScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {
  List<LedgerTransaction>? _transactions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final transactions = await transactionRepository.list(widget.householdId);
    if (!mounted) return;
    setState(() => _transactions = transactions);
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
      body: transactions == null
          ? const Center(child: CircularProgressIndicator())
          : transactions.isEmpty
              ? const Center(child: Text('아직 거래 내역이 없어요'))
              : ListView.builder(
                  itemCount: transactions.length,
                  itemBuilder: (context, i) {
                    final t = transactions[i];
                    final sign = t.type == 'expense' ? '-' : '+';
                    return ListTile(
                      title: Text('$sign${t.amount}원'),
                      subtitle: Text(t.memo ?? ''),
                    );
                  },
                ),
    );
  }
}
```

- [ ] **Step 3: Run the full test suite**

Run: `flutter test` AND `flutter analyze`
Expected: PASS. (No new automated tests in this step — these are thin screens over already-tested repositories; verifying they compile and don't regress existing tests is this step's bar. If you want to add a widget test, follow `home_screen_test.dart`'s fake-repository pattern for `TransactionListScreen`; not required.)

- [ ] **Step 4: Commit**

```bash
git add ppyu_budget/lib/features/ledger/transaction_list_screen.dart ppyu_budget/lib/features/ledger/transaction_form_screen.dart
git commit -m "feat: add transaction list and add-transaction screens"
```

---

### Task 6: Budget model + repository + screen

**Files:**
- Create: `ppyu_budget/lib/features/ledger/models/budget.dart`
- Create: `ppyu_budget/lib/features/ledger/budget_repository.dart`
- Create: `ppyu_budget/lib/features/ledger/budget_screen.dart`
- Test: `ppyu_budget/test/features/ledger/budget_repository_test.dart`

**Interfaces:**
- Consumes: `supabase` getter, `CategoryRepository`, `TransactionRepository`.
- Produces: `class Budget { id, categoryId, month, amount }`; `class BudgetRepository { Future<List<Budget>> list(String householdId, DateTime month); Future<Budget> upsert({required String householdId, String? categoryId, required DateTime month, required int amount}); }`.

- [ ] **Step 1: Write the model**

`ppyu_budget/lib/features/ledger/models/budget.dart`:
```dart
class Budget {
  const Budget({
    required this.id,
    required this.month,
    required this.amount,
    this.categoryId,
  });

  final String id;
  final String? categoryId;
  final DateTime month;
  final int amount;

  factory Budget.fromJson(Map<String, dynamic> json) => Budget(
        id: json['id'] as String,
        categoryId: json['category_id'] as String?,
        month: DateTime.parse(json['month'] as String),
        amount: json['amount'] as int,
      );
}
```

- [ ] **Step 2: Write the failing repository test**

`ppyu_budget/test/features/ledger/budget_repository_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/budget_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late BudgetRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = BudgetRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s budgets for a month', () async {
    final future = repo.list('household-1', DateTime.utc(2026, 9));

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/budgets'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    expect(request.uri.queryParameters['month'], 'eq.2026-09-01');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'b1', 'category_id': null, 'month': '2026-09-01', 'amount': 1000000},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.amount, 1000000);
    expect(result.first.categoryId, isNull);
  });

  test('upsert posts a budget with on_conflict on household/category/month', () async {
    final future = repo.upsert(
      householdId: 'household-1',
      categoryId: 'c1',
      month: DateTime.utc(2026, 9),
      amount: 300000,
    );

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/budgets'));
    expect(request.headers.value('prefer'), contains('resolution=merge-duplicates'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'category_id': 'c1',
      'month': '2026-09-01',
      'amount': 300000,
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'b2', 'category_id': 'c1', 'month': '2026-09-01', 'amount': 300000},
      ]));
    await request.response.close();

    final result = await future;
    expect(result.amount, 300000);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ledger/budget_repository_test.dart`
Expected: FAIL — `BudgetRepository` doesn't exist.

- [ ] **Step 4: Implement the repository**

`ppyu_budget/lib/features/ledger/budget_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/budget.dart';

String _monthKey(DateTime month) =>
    '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}-01';

class BudgetRepository {
  BudgetRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Budget>> list(String householdId, DateTime month) async {
    final rows = await _client
        .from('budgets')
        .select()
        .eq('household_id', householdId)
        .eq('month', _monthKey(month));
    return rows.map(Budget.fromJson).toList();
  }

  Future<Budget> upsert({
    required String householdId,
    String? categoryId,
    required DateTime month,
    required int amount,
  }) async {
    final rows = await _client.from('budgets').upsert({
      'household_id': householdId,
      'category_id': categoryId,
      'month': _monthKey(month),
      'amount': amount,
    }).select();
    return Budget.fromJson(rows.first);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/ledger/budget_repository_test.dart`
Expected: PASS

- [ ] **Step 6: Build the budget screen**

`ppyu_budget/lib/features/ledger/budget_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/budget_repository.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/models/budget.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';

final budgetRepository = BudgetRepository(client: supabase);

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  final _amountController = TextEditingController();
  List<Category>? _categories;
  List<Budget>? _budgets;
  String? _selectedCategoryId;
  final _month = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final categories = await categoryRepository.list(widget.householdId, type: 'expense');
    final budgets = await budgetRepository.list(widget.householdId, _month);
    if (!mounted) return;
    setState(() {
      _categories = categories;
      _budgets = budgets;
      _selectedCategoryId = categories.isNotEmpty ? categories.first.id : null;
    });
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amountController.text.trim());
    if (amount == null || amount < 0) return;
    await budgetRepository.upsert(
      householdId: widget.householdId,
      categoryId: _selectedCategoryId,
      month: _month,
      amount: amount,
    );
    _amountController.clear();
    _load();
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    final budgets = _budgets;
    if (categories == null || budgets == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('이번 달 예산')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: budgets.length,
              itemBuilder: (context, i) {
                final b = budgets[i];
                final categoryName = b.categoryId == null
                    ? '전체'
                    : categories
                        .firstWhere((c) => c.id == b.categoryId,
                            orElse: () => Category(id: '', name: '(삭제됨)', type: 'expense'))
                        .name;
                return ListTile(title: Text(categoryName), trailing: Text('${b.amount}원'));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                DropdownButton<String?>(
                  value: _selectedCategoryId,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('전체 예산')),
                    ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
                  ],
                  onChanged: (v) => setState(() => _selectedCategoryId = v),
                ),
                Expanded(
                  child: TextField(
                    controller: _amountController,
                    decoration: const InputDecoration(labelText: '금액'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                IconButton(icon: const Icon(Icons.check), onPressed: _save),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 7: Run the full test suite**

Run: `flutter test` AND `flutter analyze`

- [ ] **Step 8: Commit**

```bash
git add ppyu_budget/lib/features/ledger/models/budget.dart ppyu_budget/lib/features/ledger/budget_repository.dart \
        ppyu_budget/lib/features/ledger/budget_screen.dart ppyu_budget/test/features/ledger/budget_repository_test.dart
git commit -m "feat: add budget model, repository, and screen"
```

---

### Task 7: Savings goal model + repository + screen

**Files:**
- Create: `ppyu_budget/lib/features/ledger/models/savings_goal.dart`
- Create: `ppyu_budget/lib/features/ledger/savings_goal_repository.dart`
- Create: `ppyu_budget/lib/features/ledger/savings_goal_screen.dart`
- Test: `ppyu_budget/test/features/ledger/savings_goal_repository_test.dart`

**Interfaces:**
- Consumes: `supabase` getter.
- Produces: `class SavingsGoal { id, name, targetAmount, currentAmount, targetDate }`; `class SavingsGoalRepository { Future<List<SavingsGoal>> list(String householdId); Future<SavingsGoal> create({required String householdId, required String name, required int targetAmount, DateTime? targetDate}); }`.

- [ ] **Step 1: Write the model**

`ppyu_budget/lib/features/ledger/models/savings_goal.dart`:
```dart
class SavingsGoal {
  const SavingsGoal({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.currentAmount,
    this.targetDate,
  });

  final String id;
  final String name;
  final int targetAmount;
  final int currentAmount;
  final DateTime? targetDate;

  factory SavingsGoal.fromJson(Map<String, dynamic> json) => SavingsGoal(
        id: json['id'] as String,
        name: json['name'] as String,
        targetAmount: json['target_amount'] as int,
        currentAmount: json['current_amount'] as int,
        targetDate: json['target_date'] == null
            ? null
            : DateTime.parse(json['target_date'] as String),
      );
}
```

- [ ] **Step 2: Write the failing repository test**

`ppyu_budget/test/features/ledger/savings_goal_repository_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/savings_goal_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late SavingsGoalRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = SavingsGoalRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s savings goals', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/savings_goals'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 's1',
          'name': '여행자금',
          'target_amount': 3000000,
          'current_amount': 500000,
          'target_date': '2027-01-01',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '여행자금');
    expect(result.first.targetAmount, 3000000);
  });

  test('create posts a new savings goal', () async {
    final future = repo.create(
      householdId: 'household-1',
      name: '결혼자금',
      targetAmount: 10000000,
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'name': '결혼자금',
      'target_amount': 10000000,
      'target_date': null,
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 's2',
          'name': '결혼자금',
          'target_amount': 10000000,
          'current_amount': 0,
          'target_date': null,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '결혼자금');
    expect(result.currentAmount, 0);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ledger/savings_goal_repository_test.dart`
Expected: FAIL — `SavingsGoalRepository` doesn't exist.

- [ ] **Step 4: Implement the repository**

`ppyu_budget/lib/features/ledger/savings_goal_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/savings_goal.dart';

class SavingsGoalRepository {
  SavingsGoalRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<SavingsGoal>> list(String householdId) async {
    final rows = await _client
        .from('savings_goals')
        .select()
        .eq('household_id', householdId);
    return rows.map(SavingsGoal.fromJson).toList();
  }

  Future<SavingsGoal> create({
    required String householdId,
    required String name,
    required int targetAmount,
    DateTime? targetDate,
  }) async {
    final rows = await _client.from('savings_goals').insert({
      'household_id': householdId,
      'name': name,
      'target_amount': targetAmount,
      'target_date': targetDate == null
          ? null
          : '${targetDate.year.toString().padLeft(4, '0')}-${targetDate.month.toString().padLeft(2, '0')}-${targetDate.day.toString().padLeft(2, '0')}',
    }).select();
    return SavingsGoal.fromJson(rows.first);
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/ledger/savings_goal_repository_test.dart`
Expected: PASS

- [ ] **Step 6: Build the savings goal screen**

`ppyu_budget/lib/features/ledger/savings_goal_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/models/savings_goal.dart';
import 'package:ppyu_budget/features/ledger/savings_goal_repository.dart';

final savingsGoalRepository = SavingsGoalRepository(client: supabase);

class SavingsGoalScreen extends StatefulWidget {
  const SavingsGoalScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<SavingsGoalScreen> createState() => _SavingsGoalScreenState();
}

class _SavingsGoalScreenState extends State<SavingsGoalScreen> {
  final _nameController = TextEditingController();
  final _targetController = TextEditingController();
  List<SavingsGoal>? _goals;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final goals = await savingsGoalRepository.list(widget.householdId);
    if (!mounted) return;
    setState(() => _goals = goals);
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    final target = int.tryParse(_targetController.text.trim());
    if (name.isEmpty || target == null || target <= 0) return;
    await savingsGoalRepository.create(
      householdId: widget.householdId,
      name: name,
      targetAmount: target,
    );
    _nameController.clear();
    _targetController.clear();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final goals = _goals;
    return Scaffold(
      appBar: AppBar(title: const Text('저축 목표')),
      body: Column(
        children: [
          Expanded(
            child: goals == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: goals.length,
                    itemBuilder: (context, i) {
                      final g = goals[i];
                      final progress = g.targetAmount == 0 ? 0.0 : g.currentAmount / g.targetAmount;
                      return ListTile(
                        title: Text(g.name),
                        subtitle: LinearProgressIndicator(value: progress.clamp(0, 1)),
                        trailing: Text('${g.currentAmount}/${g.targetAmount}원'),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '목표 이름'),
                ),
                TextField(
                  controller: _targetController,
                  decoration: const InputDecoration(labelText: '목표 금액'),
                  keyboardType: TextInputType.number,
                ),
                ElevatedButton(onPressed: _add, child: const Text('목표 추가')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 7: Run the full test suite**

Run: `flutter test` AND `flutter analyze`

- [ ] **Step 8: Commit**

```bash
git add ppyu_budget/lib/features/ledger/models/savings_goal.dart ppyu_budget/lib/features/ledger/savings_goal_repository.dart \
        ppyu_budget/lib/features/ledger/savings_goal_screen.dart ppyu_budget/test/features/ledger/savings_goal_repository_test.dart
git commit -m "feat: add savings goal model, repository, and screen"
```

---

### Task 8: Wire the ledger into HomeScreen

**Files:**
- Modify: `ppyu_budget/lib/features/household/home_screen.dart`
- Test: `ppyu_budget/test/features/household/home_screen_test.dart` (extend)

**Interfaces:**
- Consumes: `TransactionListScreen`, `AccountScreen`, `CategoryScreen`, `BudgetScreen`, `SavingsGoalScreen` (Tasks 2-7).
- Produces: nothing new consumed elsewhere — this is the phase's final integration point.

- [ ] **Step 1: Replace the "연동됨" placeholder with real navigation**

In `ppyu_budget/lib/features/household/home_screen.dart`, replace the `if (_householdId != null)` branch's body (currently `const Scaffold(body: Center(child: Text('배우자와 연동됐어요')))`) with a simple menu:
```dart
    if (_householdId != null) {
      final householdId = _householdId!;
      return Scaffold(
        appBar: AppBar(title: const Text('쀼가계부')),
        body: ListView(
          children: [
            ListTile(
              title: const Text('거래 내역'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TransactionListScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('계좌/카드 관리'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AccountScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('카테고리 관리'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CategoryScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('이번 달 예산'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => BudgetScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('저축 목표'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SavingsGoalScreen(householdId: householdId),
              )),
            ),
          ],
        ),
      );
    }
```
Add the corresponding imports at the top of the file:
```dart
import 'package:ppyu_budget/features/ledger/account_screen.dart';
import 'package:ppyu_budget/features/ledger/budget_screen.dart';
import 'package:ppyu_budget/features/ledger/category_screen.dart';
import 'package:ppyu_budget/features/ledger/savings_goal_screen.dart';
import 'package:ppyu_budget/features/ledger/transaction_list_screen.dart';
```

- [ ] **Step 2: Update the existing widget test's assertion**

In `ppyu_budget/test/features/household/home_screen_test.dart`, the test `'hides invite/join buttons when the user already has a household'` currently only asserts the invite/join buttons are absent. Add an assertion that the new menu renders instead:
```dart
    expect(find.text('거래 내역'), findsOneWidget);
```
Add this line right after the existing `expect(find.text('초대 코드로 연동하기'), findsNothing);` line in that test.

- [ ] **Step 3: Run the full test suite**

Run: `flutter test` AND `flutter analyze`
Expected: PASS, no new analyze errors.

- [ ] **Step 4: Manual smoke check (optional, requires a real device/emulator and real OAuth credentials — skip if unavailable, same as Phase 1's Task 7 Step 10)**

If a device and real Google/Kakao credentials are available: log in, create/join a household, confirm the new menu appears and each of the 5 screens opens without crashing.

- [ ] **Step 5: Commit**

```bash
git add ppyu_budget/lib/features/household/home_screen.dart ppyu_budget/test/features/household/home_screen_test.dart
git commit -m "feat: wire ledger screens into the household home screen"
```
