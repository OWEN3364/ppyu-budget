# 통계/리포트 + 소비 절감 추천 + 태그/검색/CSV 내보내기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 이번 달 카테고리별 지출 그래프, 전월 대비 급증 카테고리 추천, 거래 태그/검색, 선택 기간 CSV 내보내기를 추가한다.

**Architecture:** 집계는 Postgres `security definer` 함수 두 개(`get_monthly_category_summary`, `get_spending_recommendations`)가 서버에서 계산해 반환하고, 클라이언트는 그 결과만 그린다. 태그는 카테고리와 같은 패턴(가구 단위 사전 정의 목록)으로 별도 테이블 + 다대다 연결 테이블로 추가한다. CSV는 서버 전송 없이 기기 안에서 문자열을 만들어 공유 시트로 넘긴다.

**Tech Stack:** Flutter (Android), Supabase (Postgres+RLS+PostgREST), `fl_chart`(신규), `share_plus`(신규)

**Spec:** `docs/superpowers/specs/2026-08-26-stats-report-recommendations-design.md`

## Global Constraints

- Android 단일 타겟, 기존 프로젝트에 iOS 관련 코드 추가하지 않는다.
- 모든 리포지토리 테스트는 실제 `SupabaseClient` + 로컬 `HttpServer`로 검증한다 (mocktail로 `.from()`/`.rpc()`를 직접 모킹하지 않는다 — `PostgrestFilterBuilder<T>`는 `Future<T>`를 구현하지만 그 자체는 아니라서 mocktail의 `thenAnswer`가 컴파일되지 않는다).
- 새 테이블은 전부 `alter table ... enable row level security`, 새 `security definer` 함수는 전부 `set search_path = public, pg_temp` + `revoke execute on function ... from public, anon`을 포함한다.
- SQL 테스트는 `begin;`/`rollback;` + `savepoint`/`rollback to savepoint` 패턴, `auth.users` insert는 `set local role authenticated;` 이전에 실행한다 (슈퍼유저 권한 필요).
- 모든 async 위젯 메서드는 await 이후 `setState` 호출 전에 `mounted` 체크, 저장/삭제류는 busy-guard bool로 중복 실행을 막는다 (기존 `_saving`/`_creating` 패턴).
- `fl_chart`/`share_plus`는 새 의존성이다 — 정확한 API는 버전마다 바뀔 수 있으니, 구현자는 `flutter pub add`로 실제 버전을 받은 뒤 설치된 패키지 소스(pub cache)를 직접 확인하고 정확한 시그니처로 작성한다. 이 문서의 예시 코드는 "이런 모양"이라는 출발점이지, 검증 없이 그대로 붙여넣을 코드가 아니다.
- 에러 메시지는 기존처럼 한국어, 실패 원인이 아니라 사용자가 할 일 위주로 짧게.

---

### Task 1: 스키마 — tags, transaction_tags, nickname

**Files:**
- Create: `supabase/migrations/0005_tags_nickname.sql`
- Test: `supabase/tests/0005_tags_nickname_test.sql`

**Interfaces:**
- Produces: `tags(id, household_id, name, created_at)`, `transaction_tags(transaction_id, tag_id)`, `household_members.nickname`, RPC `set_my_nickname(p_household_id uuid, p_nickname text) returns void`

- [ ] **Step 1: 마이그레이션 작성**

```sql
create table tags (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (household_id, name)
);

create table transaction_tags (
  transaction_id uuid not null references transactions(id) on delete cascade,
  tag_id uuid not null references tags(id) on delete cascade,
  primary key (transaction_id, tag_id)
);

alter table household_members add column nickname text;

alter table tags enable row level security;
alter table transaction_tags enable row level security;

create policy "members can select tags" on tags for select using (is_household_member(household_id));
create policy "members can insert tags" on tags for insert with check (is_household_member(household_id));
create policy "members can update tags" on tags for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete tags" on tags for delete using (is_household_member(household_id));

create policy "members can select transaction_tags" on transaction_tags for select using (
  exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))
);
create policy "members can insert transaction_tags" on transaction_tags for insert with check (
  exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))
);
create policy "members can delete transaction_tags" on transaction_tags for delete using (
  exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))
);

-- household_members has no update RLS policy today (writes only ever happened
-- via SECURITY DEFINER functions). A raw "user_id = auth.uid()" update policy
-- would let a client also overwrite `role` on their own row (self-promote to
-- 'owner') since RLS can't restrict which columns a payload touches — so
-- nickname writes go through this function instead, which only ever touches
-- the nickname column.
create or replace function set_my_nickname(p_household_id uuid, p_nickname text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_household_member(p_household_id) then
    raise exception 'not_a_household_member';
  end if;
  update household_members
  set nickname = p_nickname
  where household_id = p_household_id and user_id = auth.uid();
end;
$$;
revoke execute on function set_my_nickname(uuid, text) from public, anon;
```

- [ ] **Step 2: 적용**

Run: `supabase db push --linked` (또는 프로젝트에서 쓰는 기존 마이그레이션 적용 명령 — 이전 태스크들과 동일하게)

- [ ] **Step 3: SQL 테스트 작성**

`supabase/tests/0004_transaction_source_merchant_test.sql`과 동일한 `begin;`/`savepoint`/`rollback to savepoint` 패턴을 그대로 따른다.

```sql
-- Run with: supabase db query --linked --file supabase/tests/0005_tags_nickname_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- tags are scoped to the creating household; another household can't see them
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_tag_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  insert into tags (household_id, name) values (v_household_a, '배달') returning id into v_tag_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select count(*) into v_count from tags where id = v_tag_id;
  if v_count != 0 then
    raise exception 'TEST FAILED: household B could see household A''s tag';
  end if;
end $$;
rollback to savepoint sp1;

-- set_my_nickname only updates the caller's own row, never another member's
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_other_member_id uuid;
  v_nickname text;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();

  perform set_my_nickname(v_household_id, '민수');
  select nickname into v_nickname from household_members
    where household_id = v_household_id and user_id = auth.uid();
  if v_nickname != '민수' then
    raise exception 'TEST FAILED: expected own nickname to be set, got %', v_nickname;
  end if;
end $$;
rollback to savepoint sp2;

-- set_my_nickname raises for a non-member household
savepoint sp3;
do $$
declare
  v_household_id uuid;
  v_raised boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  begin
    perform set_my_nickname(v_household_id, '해킹시도');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST FAILED: non-member should not be able to set a nickname';
  end if;
end $$;
rollback to savepoint sp3;

rollback;
```

- [ ] **Step 4: 테스트 실행**

Run: `supabase db query --linked --file supabase/tests/0005_tags_nickname_test.sql`
Expected: 에러 없이 종료 (raise exception 없음)

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0005_tags_nickname.sql supabase/tests/0005_tags_nickname_test.sql
git commit -m "feat(db): add tags, transaction_tags, and nickname support"
```

---

### Task 2: 스키마 — 통계/추천 함수

**Files:**
- Create: `supabase/migrations/0006_stats_functions.sql`
- Test: `supabase/tests/0006_stats_functions_test.sql`

**Interfaces:**
- Produces: RPC `get_monthly_category_summary(p_household_id uuid, p_month date) returns table(category_id uuid, category_name text, type text, total_amount bigint)`, RPC `get_spending_recommendations(p_household_id uuid, p_month date) returns table(category_id uuid, category_name text, current_amount bigint, previous_amount bigint, change_ratio double precision)`

- [ ] **Step 1: 마이그레이션 작성**

```sql
create or replace function get_monthly_category_summary(p_household_id uuid, p_month date)
returns table (category_id uuid, category_name text, type text, total_amount bigint)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select c.id, c.name, c.type, coalesce(sum(t.amount), 0)
  from categories c
  left join transactions t
    on t.category_id = c.id
    and t.household_id = p_household_id
    and date_trunc('month', t.occurred_at) = date_trunc('month', p_month::timestamptz)
  where c.household_id = p_household_id
    and is_household_member(p_household_id)
  group by c.id, c.name, c.type
  having coalesce(sum(t.amount), 0) > 0;
$$;
revoke execute on function get_monthly_category_summary(uuid, date) from public, anon;

create or replace function get_spending_recommendations(p_household_id uuid, p_month date)
returns table (category_id uuid, category_name text, current_amount bigint, previous_amount bigint, change_ratio double precision)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  with current_month as (
    select * from get_monthly_category_summary(p_household_id, p_month) where type = 'expense'
  ), previous_month as (
    select * from get_monthly_category_summary(p_household_id, (p_month - interval '1 month')::date) where type = 'expense'
  )
  select cm.category_id, cm.category_name, cm.total_amount, coalesce(pm.total_amount, 0),
    round((cm.total_amount - pm.total_amount)::numeric / pm.total_amount * 100, 1)::double precision
  from current_month cm
  join previous_month pm on pm.category_id = cm.category_id
  where pm.total_amount > 0
    and (cm.total_amount - pm.total_amount)::numeric / pm.total_amount > 0.2
  order by (cm.total_amount - pm.total_amount)::numeric / pm.total_amount desc
  limit 3;
$$;
revoke execute on function get_spending_recommendations(uuid, date) from public, anon;
```

`join`(not `left join`)으로 전월 데이터가 아예 없는 카테고리를 자연스럽게 제외한다 — `having`절 때문에 0원인 달은 `get_monthly_category_summary` 결과에 아예 나타나지 않으므로, "이번 달 처음 지출한 카테고리"는 전월 행이 없어 join에서 저절로 빠진다(무한대 증가율로 잘못 추천되는 것 방지).

- [ ] **Step 2: 적용**

Run: `supabase db push --linked`

- [ ] **Step 3: SQL 테스트 작성**

```sql
-- Run with: supabase db query --linked --file supabase/tests/0006_stats_functions_test.sql
begin;

insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;

set local role authenticated;

-- category with >20% MoM increase is recommended; category with no prior-month
-- spending is excluded even though its "increase" is technically infinite
savepoint sp1;
do $$
declare
  v_household_id uuid;
  v_member_id uuid;
  v_account_id uuid;
  v_food_category uuid;
  v_new_category uuid;
  v_rec_count integer;
  v_food_ratio double precision;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_id from household_members where household_id = v_household_id and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_id, '테스트카드') returning id into v_account_id;
  select id into v_food_category from categories where household_id = v_household_id and name = '식비';
  insert into categories (household_id, name, type) values (v_household_id, '신규카테고리', 'expense') returning id into v_new_category;

  -- last month: 식비 100,000
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at)
  values (v_household_id, v_account_id, v_food_category, v_member_id, 'expense', 100000, date_trunc('month', now()) - interval '15 days');

  -- this month: 식비 150,000 (+50%), 신규카테고리 50,000 (no prior month)
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at)
  values (v_household_id, v_account_id, v_food_category, v_member_id, 'expense', 150000, now());
  insert into transactions (household_id, account_id, category_id, member_id, type, amount, occurred_at)
  values (v_household_id, v_account_id, v_new_category, v_member_id, 'expense', 50000, now());

  select count(*) into v_rec_count from get_spending_recommendations(v_household_id, now()::date)
    where category_id = v_new_category;
  if v_rec_count != 0 then
    raise exception 'TEST FAILED: category with no prior-month spending must not be recommended';
  end if;

  select change_ratio into v_food_ratio from get_spending_recommendations(v_household_id, now()::date)
    where category_id = v_food_category;
  if v_food_ratio is null or v_food_ratio != 50.0 then
    raise exception 'TEST FAILED: expected 식비 change_ratio 50.0, got %', v_food_ratio;
  end if;
end $$;
rollback to savepoint sp1;

-- another household's data never leaks into these functions
savepoint sp2;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_account_a uuid;
  v_category_a uuid;
  v_leak_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into accounts (household_id, name) values (v_household_a, '카드A') returning id into v_account_a;
  select id into v_category_a from categories where household_id = v_household_a and name = '식비';
  insert into transactions (household_id, account_id, category_id, member_id, type, amount)
  values (v_household_a, v_account_a, v_category_a, v_member_a, 'expense', 999999);

  v_household_b := gen_random_uuid(); -- a household this session is not a member of
  select count(*) into v_leak_count from get_monthly_category_summary(v_household_b, now()::date);
  if v_leak_count != 0 then
    raise exception 'TEST FAILED: get_monthly_category_summary leaked data for a non-member household';
  end if;
end $$;
rollback to savepoint sp2;

rollback;
```

- [ ] **Step 4: 테스트 실행**

Run: `supabase db query --linked --file supabase/tests/0006_stats_functions_test.sql`
Expected: 에러 없이 종료

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0006_stats_functions.sql supabase/tests/0006_stats_functions_test.sql
git commit -m "feat(db): add monthly category summary and spending recommendation functions"
```

---

### Task 3: TagRepository + 태그 관리 화면

**Files:**
- Create: `lib/features/ledger/models/tag.dart`
- Create: `lib/features/ledger/tag_repository.dart`
- Create: `lib/features/ledger/tag_management_screen.dart`
- Modify: `lib/features/household/home_screen.dart` (메뉴 항목 추가)
- Test: `test/features/ledger/tag_repository_test.dart`

**Interfaces:**
- Produces: `Tag {id, name}`, `TagRepository.list(householdId)`, `.create(householdId, name)`, `.delete(tagId)`, top-level `tagRepository` instance (다른 화면이 import해서 재사용 — `category_screen.dart`의 `categoryRepository` 패턴과 동일)

- [ ] **Step 1: Tag 모델**

`lib/features/ledger/models/tag.dart`:
```dart
class Tag {
  const Tag({required this.id, required this.name});

  final String id;
  final String name;

  factory Tag.fromJson(Map<String, dynamic> json) => Tag(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}
```

- [ ] **Step 2: TagRepository**

`lib/features/ledger/tag_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/tag.dart';

class TagRepository {
  TagRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Tag>> list(String householdId) async {
    final rows = await _client.from('tags').select().eq('household_id', householdId);
    return rows.map(Tag.fromJson).toList();
  }

  Future<Tag> create(String householdId, String name) async {
    final rows = await _client.from('tags').insert({
      'household_id': householdId,
      'name': name,
    }).select();
    return Tag.fromJson(rows.first);
  }

  Future<void> delete(String tagId) async {
    await _client.from('tags').delete().eq('id', tagId);
  }
}
```

- [ ] **Step 3: 리포지토리 테스트**

`test/features/ledger/tag_repository_test.dart` (기존 `category_repository_test.dart`와 동일한 `HttpServer` 패턴):
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/tag_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late TagRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = TagRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s tags', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/tags'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'tag-1', 'name': '배달'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '배달');
  });

  test('create posts a new tag', () async {
    final future = repo.create('household-1', '여행');

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'household_id': 'household-1', 'name': '여행'});
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'tag-2', 'name': '여행'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '여행');
  });

  test('delete removes a tag by id', () async {
    final future = repo.delete('tag-1');

    final request = await mockServer.first;
    expect(request.method, 'DELETE');
    expect(request.uri.path, endsWith('/tags'));
    expect(request.uri.queryParameters['id'], 'eq.tag-1');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });
}
```

- [ ] **Step 4: 테스트 실행**

Run: `flutter test test/features/ledger/tag_repository_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: 태그 관리 화면**

`lib/features/ledger/tag_management_screen.dart` (`category_screen.dart`와 동일한 구조 — 목록+추가+삭제):
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/tag_repository.dart';
import 'package:ppyu_budget/features/ledger/models/tag.dart';

final tagRepository = TagRepository(client: supabase);

class TagManagementScreen extends StatefulWidget {
  const TagManagementScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TagManagementScreen> createState() => _TagManagementScreenState();
}

class _TagManagementScreenState extends State<TagManagementScreen> {
  final _nameController = TextEditingController();
  List<Tag>? _tags;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tags = await tagRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _tags = tags;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '태그를 불러오지 못했어요');
    }
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await tagRepository.create(widget.householdId, name);
      _nameController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '이미 있는 태그이거나 추가에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(String tagId) async {
    setState(() => _error = null);
    try {
      await tagRepository.delete(tagId);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '태그 삭제에 실패했어요');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    return Scaffold(
      appBar: AppBar(title: const Text('태그 관리')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: tags == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: tags.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(tags[i].name),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _delete(tags[i].id),
                      ),
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
                    decoration: const InputDecoration(labelText: '새 태그'),
                  ),
                ),
                IconButton(icon: const Icon(Icons.add), onPressed: _saving ? null : _add),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: 홈 화면에 메뉴 추가**

`lib/features/household/home_screen.dart`의 `ListTile` 목록(카테고리 관리 항목 바로 아래)에 추가:
```dart
            ListTile(
              title: const Text('태그 관리'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TagManagementScreen(householdId: householdId),
              )),
            ),
```
그리고 파일 상단 import에 `import 'package:ppyu_budget/features/ledger/tag_management_screen.dart';` 추가.

- [ ] **Step 7: Commit**

```bash
git add lib/features/ledger/models/tag.dart lib/features/ledger/tag_repository.dart lib/features/ledger/tag_management_screen.dart lib/features/household/home_screen.dart test/features/ledger/tag_repository_test.dart
git commit -m "feat(ledger): add tag management (list/create/delete)"
```

---

### Task 4: 거래 ↔ 태그 연결

**Files:**
- Modify: `lib/features/ledger/models/transaction.dart`
- Modify: `lib/features/ledger/transaction_repository.dart`
- Modify: `test/features/ledger/transaction_repository_test.dart`

**Interfaces:**
- Consumes: `TagRepository`(Task 3, 화면에서 태그 이름 조회용으로만 — 이 태스크의 리포지토리 코드는 태그 이름을 몰라도 됨)
- Produces: `LedgerTransaction.tagIds` (`List<String>`), `TransactionRepository.create(..., {List<String> tagIds = const []})`, `.update(..., {List<String> tagIds = const []})`, `.setTags(String transactionId, List<String> tagIds)`

- [ ] **Step 1: 모델에 tagIds 추가**

`lib/features/ledger/models/transaction.dart`을 아래로 교체:
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
    this.tagIds = const [],
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
  final List<String> tagIds;

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
        tagIds: (json['transaction_tags'] as List<dynamic>? ?? [])
            .map((e) => (e as Map<String, dynamic>)['tag_id'] as String)
            .toList(),
      );
}
```

- [ ] **Step 2: 리포지토리에 태그 반영**

`lib/features/ledger/transaction_repository.dart`을 아래로 교체:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';

class TransactionRepository {
  TransactionRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<LedgerTransaction>> list(String householdId) async {
    final rows = await _client
        .from('transactions')
        .select('*, transaction_tags(tag_id)')
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
    List<String> tagIds = const [],
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
    final transaction = LedgerTransaction.fromJson(rows.first);
    // a brand-new row can't have existing tags, so there's nothing to clear —
    // skip setTags entirely rather than firing a DELETE that can only ever
    // affect zero rows
    if (tagIds.isNotEmpty) {
      await setTags(transaction.id, tagIds);
    }
    return LedgerTransaction.fromJson({...rows.first, 'transaction_tags': tagIds.map((id) => {'tag_id': id}).toList()});
  }

  Future<LedgerTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String type,
    required int amount,
    String? memo,
    String? merchant,
    List<String> tagIds = const [],
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
    await setTags(id, tagIds);
    return LedgerTransaction.fromJson({...rows.first, 'transaction_tags': tagIds.map((tagId) => {'tag_id': tagId}).toList()});
  }

  /// Replaces every tag on [transactionId] with [tagIds] (delete-then-insert
  /// — simpler and more idempotent than diffing old vs new tag sets).
  Future<void> setTags(String transactionId, List<String> tagIds) async {
    await _client.from('transaction_tags').delete().eq('transaction_id', transactionId);
    if (tagIds.isEmpty) return;
    await _client.from('transaction_tags').insert(
          tagIds.map((tagId) => {'transaction_id': transactionId, 'tag_id': tagId}).toList(),
        );
  }

  Future<void> delete(String id) async {
    await _client.from('transactions').delete().eq('id', id);
  }
}
```

`create`/`update`가 서버 응답(`rows.first`, `transaction_tags` 없이 옴)에 방금 저장한 `tagIds`를 수동으로 합쳐 반환하는 이유: `insert().select()`/`update().select()`는 `transactions` 테이블 자체 컬럼만 반환하고 방금 `setTags`로 반영한 `transaction_tags`는 포함하지 않는다. 화면이 저장 직후 반환값의 `tagIds`를 바로 신뢰할 수 있어야 태그 칩이 저장 후에도 깜빡이지 않는다.

- [ ] **Step 3: 리포지토리 테스트 갱신**

`test/features/ledger/transaction_repository_test.dart`에 아래 테스트를 추가한다 (기존 테스트들 아래에). 이 테스트는 `create()`가 태그 삭제+삽입까지 포함해 여러 HTTP 요청을 순서대로 처리하므로, `mockServer.first`를 반복 호출하면 안 된다 — Task 7(Phase 3)의 리뷰에서 확인된 것처럼 `HttpServer.first`는 첫 요청을 소비한 뒤 스트림을 닫아버려서 반복 호출이 깨진다. 대신 `StreamIterator`로 순서대로 소비한다:
```dart
test('create saves the transaction then replaces its tags', () async {
  final iterator = StreamIterator(mockServer);
  final future = repo.create(
    householdId: 'household-1',
    accountId: 'account-1',
    categoryId: 'category-1',
    memberId: 'member-1',
    type: 'expense',
    amount: 5000,
    tagIds: ['tag-1', 'tag-2'],
  );

  await iterator.moveNext();
  final insertRequest = iterator.current;
  expect(insertRequest.method, 'POST');
  expect(insertRequest.uri.path, endsWith('/transactions'));
  insertRequest.response
    ..statusCode = HttpStatus.created
    ..headers.contentType = ContentType.json
    ..write(jsonEncode([
      {
        'id': 'txn-1',
        'account_id': 'account-1',
        'category_id': 'category-1',
        'member_id': 'member-1',
        'type': 'expense',
        'amount': 5000,
        'occurred_at': '2026-08-26T00:00:00Z',
        'source': 'manual',
        'memo': null,
        'merchant': null,
      },
    ]));
  await insertRequest.response.close();

  await iterator.moveNext();
  final deleteTagsRequest = iterator.current;
  expect(deleteTagsRequest.method, 'DELETE');
  expect(deleteTagsRequest.uri.path, endsWith('/transaction_tags'));
  deleteTagsRequest.response.statusCode = HttpStatus.noContent;
  await deleteTagsRequest.response.close();

  await iterator.moveNext();
  final insertTagsRequest = iterator.current;
  expect(insertTagsRequest.method, 'POST');
  expect(insertTagsRequest.uri.path, endsWith('/transaction_tags'));
  final bodyStr = await utf8.decodeStream(insertTagsRequest);
  expect(jsonDecode(bodyStr), [
    {'transaction_id': 'txn-1', 'tag_id': 'tag-1'},
    {'transaction_id': 'txn-1', 'tag_id': 'tag-2'},
  ]);
  insertTagsRequest.response.statusCode = HttpStatus.created;
  await insertTagsRequest.response.close();

  final result = await future;
  expect(result.id, 'txn-1');
  expect(result.tagIds, ['tag-1', 'tag-2']);
});
```
파일 상단에 `import 'dart:async';`가 없다면 추가한다 (`StreamIterator`용).

- [ ] **Step 4: 테스트 실행**

Run: `flutter test test/features/ledger/transaction_repository_test.dart`
Expected: PASS (기존 테스트 전부 + 신규 1개)

- [ ] **Step 5: Commit**

```bash
git add lib/features/ledger/models/transaction.dart lib/features/ledger/transaction_repository.dart test/features/ledger/transaction_repository_test.dart
git commit -m "feat(ledger): connect transactions to tags via transaction_tags"
```

---

### Task 5: 거래 작성/수정 화면에 태그 선택 UI

**Files:**
- Modify: `lib/features/ledger/transaction_form_screen.dart`
- Modify: `lib/features/ledger/transaction_detail_screen.dart`

**Interfaces:**
- Consumes: `tagRepository`(Task 3), `TransactionRepository.create/update(..., tagIds: ...)`(Task 4), `LedgerTransaction.tagIds`(Task 4)

- [ ] **Step 1: `transaction_form_screen.dart`에 태그 로드+선택 추가**

`import 'package:ppyu_budget/features/ledger/tag_management_screen.dart' show tagRepository;`를 import에 추가.

`_TransactionFormScreenState`에 필드 추가:
```dart
  List<Tag>? _tags;
  final Set<String> _selectedTagIds = {};
```
(`import 'package:ppyu_budget/features/ledger/models/tag.dart';` 추가)

`_loadOptions()`을 아래처럼 태그도 같이 불러오도록 수정 (계좌/카테고리 로드와 병렬로, 타입에 안 걸리므로 `requestedType` 가드 대상이 아님):
```dart
  Future<void> _loadOptions() async {
    final requestedType = _type;
    try {
      final accounts = await accountRepository.list(widget.householdId);
      final categories = await categoryRepository.list(widget.householdId, type: _type);
      final tags = _tags ?? await tagRepository.list(widget.householdId);
      if (!mounted || requestedType != _type) return;
      setState(() {
        _accounts = accounts;
        _categories = categories;
        _tags = tags;
        _accountId = accounts.isNotEmpty ? accounts.first.id : null;
        _categoryId = categories.isNotEmpty ? categories.first.id : null;
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestedType != _type) return;
      setState(() => _error = '계좌/카테고리/태그를 불러오지 못했어요');
    }
  }
```
(`_tags ?? await ...`로 타입 전환 시 매번 다시 불러오지 않게 한다 — 태그 목록은 타입과 무관하다.)

`_save()`의 `create(...)` 호출에 `tagIds: _selectedTagIds.toList(),` 추가.

`build()`의 계좌/카테고리 드롭다운과 메모 필드 사이에 태그 칩 UI 추가:
```dart
            if (_tags != null && _tags!.isNotEmpty)
              Wrap(
                spacing: 8,
                children: _tags!.map((tag) {
                  final selected = _selectedTagIds.contains(tag.id);
                  return FilterChip(
                    label: Text(tag.name),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedTagIds.add(tag.id);
                      } else {
                        _selectedTagIds.remove(tag.id);
                      }
                    }),
                  );
                }).toList(),
              ),
```

- [ ] **Step 2: `transaction_detail_screen.dart`에 동일하게 추가**

`import 'package:ppyu_budget/features/ledger/tag_management_screen.dart' show tagRepository;`와 `import 'package:ppyu_budget/features/ledger/models/tag.dart';` 추가.

필드 추가:
```dart
  List<Tag>? _tags;
  late final Set<String> _selectedTagIds = widget.transaction.tagIds.toSet();
```

`_loadOptions()`에 태그 로드 추가 (Step 1과 동일하게 `_tags ?? await tagRepository.list(...)`, `setState` 안에 `_tags = tags` 추가).

`_save()`의 `transactionRepository.update(...)` 호출에 `tagIds: _selectedTagIds.toList(),` 추가.

`build()`에 Step 1과 동일한 `FilterChip` `Wrap` 위젯 추가 (사용처 필드와 메모 필드 사이).

- [ ] **Step 3: 수동 확인**

Run: `flutter analyze`
Expected: 새 에러 없음 (기존 19개 pre-existing 이슈는 그대로 있을 수 있음 — Phase 3 최종 검증에서 이미 touched code 기준 clean 확인된 baseline)

- [ ] **Step 4: Commit**

```bash
git add lib/features/ledger/transaction_form_screen.dart lib/features/ledger/transaction_detail_screen.dart
git commit -m "feat(ledger): add tag picker to transaction create/edit screens"
```

---

### Task 6: 닉네임 (입력자 표시)

**Files:**
- Modify: `lib/features/household/household_repository.dart`
- Modify: `lib/features/household/home_screen.dart`
- Modify: `test/features/household/household_repository_test.dart`

**Interfaces:**
- Consumes: RPC `set_my_nickname`(Task 1)
- Produces: `HouseholdRepository.setMyNickname(householdId, nickname)`, `.nicknamesByMemberId(householdId)` (`Future<Map<String, String>>`, memberId → 닉네임 또는 "가족 구성원")

- [ ] **Step 1: 리포지토리에 메서드 추가**

`lib/features/household/household_repository.dart`에 추가:
```dart
  Future<void> setMyNickname(String householdId, String nickname) async {
    await _client.rpc('set_my_nickname', params: {
      'p_household_id': householdId,
      'p_nickname': nickname,
    });
  }

  Future<Map<String, String>> nicknamesByMemberId(String householdId) async {
    final rows = await _client
        .from('household_members')
        .select('id, nickname')
        .eq('household_id', householdId);
    return {
      for (final row in rows)
        row['id'] as String:
            (row['nickname'] as String?)?.isNotEmpty == true ? row['nickname'] as String : '가족 구성원',
    };
  }
```

- [ ] **Step 2: 테스트 추가**

`test/features/household/household_repository_test.dart` 기존 테스트들 아래에:
```dart
  test('setMyNickname calls the set_my_nickname RPC', () async {
    final future = repo.setMyNickname('household-1', '민수');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/set_my_nickname'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'p_household_id': 'household-1', 'p_nickname': '민수'});
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write('null');
    await request.response.close();

    await future;
  });

  test('nicknamesByMemberId maps member id to nickname, defaulting when unset', () async {
    final future = repo.nicknamesByMemberId('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/household_members'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'member-1', 'nickname': '민수'},
        {'id': 'member-2', 'nickname': null},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, {'member-1': '민수', 'member-2': '가족 구성원'});
  });
```

- [ ] **Step 3: 테스트 실행**

Run: `flutter test test/features/household/household_repository_test.dart`
Expected: PASS (기존 테스트 + 신규 2개)

- [ ] **Step 4: 홈 화면에 닉네임 설정 다이얼로그 추가**

`home_screen.dart`의 `_HomeScreenState`에 메서드 추가:
```dart
  Future<void> _setNickname(String householdId) async {
    final controller = TextEditingController();
    final nickname = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('닉네임 설정'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: '닉네임')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (nickname == null || nickname.isEmpty) return;
    try {
      await _repository.setMyNickname(householdId, nickname);
    } catch (e) {
      if (mounted) setState(() => _error = '닉네임 저장에 실패했어요');
    }
  }
```
`ListTile` 목록에 추가 (태그 관리 항목 아래):
```dart
            ListTile(
              title: const Text('닉네임 설정'),
              onTap: () => _setNickname(householdId),
            ),
```

- [ ] **Step 5: Commit**

```bash
git add lib/features/household/household_repository.dart lib/features/household/home_screen.dart test/features/household/household_repository_test.dart
git commit -m "feat(household): add nickname support for member display"
```

---

### Task 7: StatsRepository

**Files:**
- Create: `lib/features/stats/models/category_summary.dart`
- Create: `lib/features/stats/models/spending_recommendation.dart`
- Create: `lib/features/stats/stats_repository.dart`
- Test: `test/features/stats/stats_repository_test.dart`

**Interfaces:**
- Consumes: RPC `get_monthly_category_summary`, `get_spending_recommendations` (Task 2)
- Produces: `CategorySummary{categoryId, categoryName, type, totalAmount}`, `SpendingRecommendation{categoryId, categoryName, currentAmount, previousAmount, changeRatio}`, `StatsRepository.monthlyCategorySummary(householdId, month)`, `.spendingRecommendations(householdId, month)`

- [ ] **Step 1: 모델**

`lib/features/stats/models/category_summary.dart`:
```dart
class CategorySummary {
  const CategorySummary({
    required this.categoryId,
    required this.categoryName,
    required this.type,
    required this.totalAmount,
  });

  final String categoryId;
  final String categoryName;
  final String type;
  final int totalAmount;

  factory CategorySummary.fromJson(Map<String, dynamic> json) => CategorySummary(
        categoryId: json['category_id'] as String,
        categoryName: json['category_name'] as String,
        type: json['type'] as String,
        totalAmount: (json['total_amount'] as num).toInt(),
      );
}
```

`lib/features/stats/models/spending_recommendation.dart`:
```dart
class SpendingRecommendation {
  const SpendingRecommendation({
    required this.categoryId,
    required this.categoryName,
    required this.currentAmount,
    required this.previousAmount,
    required this.changeRatio,
  });

  final String categoryId;
  final String categoryName;
  final int currentAmount;
  final int previousAmount;
  final double changeRatio;

  factory SpendingRecommendation.fromJson(Map<String, dynamic> json) => SpendingRecommendation(
        categoryId: json['category_id'] as String,
        categoryName: json['category_name'] as String,
        currentAmount: (json['current_amount'] as num).toInt(),
        previousAmount: (json['previous_amount'] as num).toInt(),
        changeRatio: (json['change_ratio'] as num).toDouble(),
      );
}
```

- [ ] **Step 2: StatsRepository**

`lib/features/stats/stats_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/stats/models/category_summary.dart';
import 'package:ppyu_budget/features/stats/models/spending_recommendation.dart';

String _monthKey(DateTime month) =>
    '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}-01';

class StatsRepository {
  StatsRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<CategorySummary>> monthlyCategorySummary(String householdId, DateTime month) async {
    final result = await _client.rpc('get_monthly_category_summary', params: {
      'p_household_id': householdId,
      'p_month': _monthKey(month),
    });
    return (result as List).map((r) => CategorySummary.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<List<SpendingRecommendation>> spendingRecommendations(String householdId, DateTime month) async {
    final result = await _client.rpc('get_spending_recommendations', params: {
      'p_household_id': householdId,
      'p_month': _monthKey(month),
    });
    return (result as List).map((r) => SpendingRecommendation.fromJson(r as Map<String, dynamic>)).toList();
  }
}
```
(`_monthKey`은 `budget_repository.dart`에 이미 있는 것과 같은 모양 — 기존 프로젝트가 공유 유틸 없이 파일별로 이 짧은 헬퍼를 중복해 쓰는 컨벤션이라 그대로 따른다.)

- [ ] **Step 3: 테스트**

`test/features/stats/stats_repository_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/stats/stats_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late StatsRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = StatsRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('monthlyCategorySummary calls the RPC with a normalized month key', () async {
    final future = repo.monthlyCategorySummary('household-1', DateTime(2026, 8, 15));

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/get_monthly_category_summary'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'p_household_id': 'household-1', 'p_month': '2026-08-01'});
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'category_id': 'c1', 'category_name': '식비', 'type': 'expense', 'total_amount': 150000},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.totalAmount, 150000);
  });

  test('spendingRecommendations parses change_ratio', () async {
    final future = repo.spendingRecommendations('household-1', DateTime(2026, 8, 15));

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/get_spending_recommendations'));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'category_id': 'c1',
          'category_name': '식비',
          'current_amount': 150000,
          'previous_amount': 100000,
          'change_ratio': 50.0,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.changeRatio, 50.0);
  });
}
```

- [ ] **Step 4: 테스트 실행**

Run: `flutter test test/features/stats/stats_repository_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/features/stats/models/category_summary.dart lib/features/stats/models/spending_recommendation.dart lib/features/stats/stats_repository.dart test/features/stats/stats_repository_test.dart
git commit -m "feat(stats): add StatsRepository wrapping monthly summary and recommendation RPCs"
```

---

### Task 8: 통계 화면 (그래프 + 추천 카드)

**Files:**
- Modify: `pubspec.yaml` (fl_chart 추가)
- Create: `lib/features/stats/stats_screen.dart`
- Modify: `lib/features/household/home_screen.dart` (메뉴 항목 + 홈 화면 추천 카드)

**Interfaces:**
- Consumes: `StatsRepository`(Task 7), `CategorySummary`, `SpendingRecommendation`

- [ ] **Step 1: fl_chart 추가**

Run: `flutter pub add fl_chart`

설치된 버전의 실제 API(파이 차트 `PieChart`/`PieChartData`/`PieChartSectionData`, 필요하면 예제는 `~/.pub-cache/hosted/pub.dev/fl_chart-<version>/example` 또는 README)를 먼저 확인하고 아래 Step 2를 그 시그니처에 맞게 작성한다. 아래 코드는 출발점이지 최종본이 아니다.

- [ ] **Step 2: 통계 화면**

`lib/features/stats/stats_screen.dart` (개요 — 실제 `PieChart` 위젯 부분은 설치된 fl_chart API로 검증 후 채운다):
```dart
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/stats/models/category_summary.dart';
import 'package:ppyu_budget/features/stats/models/spending_recommendation.dart';
import 'package:ppyu_budget/features/stats/stats_repository.dart';

final statsRepository = StatsRepository(client: supabase);

const _chartColors = [
  Colors.blue, Colors.red, Colors.green, Colors.orange,
  Colors.purple, Colors.teal, Colors.brown, Colors.pink,
];

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  List<CategorySummary>? _summary;
  List<SpendingRecommendation>? _recommendations;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final requestedMonth = _month;
    try {
      final summary = await statsRepository.monthlyCategorySummary(widget.householdId, _month);
      final recommendations = await statsRepository.spendingRecommendations(widget.householdId, _month);
      if (!mounted || requestedMonth != _month) return;
      setState(() {
        _summary = summary;
        _recommendations = recommendations;
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestedMonth != _month) return;
      setState(() => _error = '통계를 불러오지 못했어요');
    }
  }

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta, 1);
      _summary = null;
      _recommendations = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final recommendations = _recommendations;
    final expenseCategories = summary?.where((s) => s.type == 'expense').toList() ?? [];
    final total = expenseCategories.fold<int>(0, (sum, s) => sum + s.totalAmount);

    return Scaffold(
      appBar: AppBar(title: const Text('통계')),
      body: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _changeMonth(-1)),
              Text('${_month.year}년 ${_month.month}월'),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _changeMonth(1)),
            ],
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          if (summary == null)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (expenseCategories.isEmpty)
            const Expanded(child: Center(child: Text('이번 달 기록된 거래가 없어요')))
          else ...[
            SizedBox(
              height: 240,
              child: PieChart(
                PieChartData(
                  sections: [
                    for (var i = 0; i < expenseCategories.length; i++)
                      PieChartSectionData(
                        value: expenseCategories[i].totalAmount.toDouble(),
                        title: expenseCategories[i].categoryName,
                        color: _chartColors[i % _chartColors.length],
                      ),
                  ],
                ),
              ),
            ),
            if (recommendations != null && recommendations.isNotEmpty)
              Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('소비 절감 추천', style: TextStyle(fontWeight: FontWeight.bold)),
                      for (final r in recommendations)
                        Text('${r.categoryName} 지출이 전월 대비 ${r.changeRatio.toStringAsFixed(0)}% 늘었어요'),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: 홈 화면에 메뉴 + 요약 추천 카드 추가**

`home_screen.dart` import에 `import 'package:ppyu_budget/features/stats/stats_screen.dart';` 추가.

`ListTile` 목록에 추가 (거래 내역 항목 근처):
```dart
            ListTile(
              title: const Text('통계'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => StatsScreen(householdId: householdId),
              )),
            ),
```

이번 태스크는 리스트 메뉴 항목까지만 다룬다 — 홈 화면 상단 추천 카드는 Task 7의 `StatsRepository.spendingRecommendations`를 재사용한다. `future:`에 `build()` 안에서 직접 RPC 호출을 넣으면 `_creating`/`_error` 등 무관한 상태가 바뀔 때마다(예: 초대 생성) 매번 다시 호출되므로, `_HomeScreenState`에 필드로 캐싱한다:
```dart
  Future<List<SpendingRecommendation>>? _recommendationsFuture;
```
`_loadHousehold()`을 아래처럼 수정 (household가 있을 때만 한 번 계산):
```dart
  Future<void> _loadHousehold() async {
    final householdId = await _repository.getMyHousehold();
    if (!mounted) return;
    setState(() {
      _householdId = householdId;
      _loading = false;
      _recommendationsFuture =
          householdId != null ? statsRepository.spendingRecommendations(householdId, DateTime.now()) : null;
    });
  }
```
`ListView`의 첫 children으로 추가 (다른 `ListTile`들보다 위):
```dart
            FutureBuilder<List<SpendingRecommendation>>(
              future: _recommendationsFuture,
              builder: (context, snapshot) {
                final recs = snapshot.data;
                if (recs == null || recs.isEmpty) return const SizedBox.shrink();
                return Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('${recs.first.categoryName} 지출이 전월 대비 ${recs.first.changeRatio.toStringAsFixed(0)}% 늘었어요'),
                  ),
                );
              },
            ),
```
(`import 'package:ppyu_budget/features/stats/models/spending_recommendation.dart';`, `import 'package:ppyu_budget/features/stats/stats_screen.dart' show statsRepository;` 추가 — RPC 실패시 `snapshot.data`가 null이라 카드가 조용히 숨겨진다.)

- [ ] **Step 4: 수동 확인**

Run: `flutter analyze`
Expected: 새 에러 없음

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/features/stats/stats_screen.dart lib/features/household/home_screen.dart
git commit -m "feat(stats): add monthly category chart and recommendation card"
```

---

### Task 9: CSV 내보내기

**Files:**
- Modify: `pubspec.yaml` (share_plus 추가)
- Create: `lib/features/stats/csv_export.dart`
- Test: `test/features/stats/csv_export_test.dart`
- Modify: `lib/features/stats/stats_screen.dart`

**Interfaces:**
- Consumes: `LedgerTransaction`(tagIds 포함, Task 4), `TransactionRepository.list`(Task 4), `TagRepository.list`(Task 3), `HouseholdRepository.nicknamesByMemberId`(Task 6), `AccountRepository`/`CategoryRepository`(기존)
- Produces: 순수 함수 `buildTransactionsCsv(...)` (테스트 가능, 위젯/네트워크 의존 없음)

- [ ] **Step 1: share_plus 추가**

Run: `flutter pub add share_plus`

설치된 버전의 실제 공유 API(예: `Share.shareXFiles` 정적 메서드 또는 `SharePlus.instance.share(ShareParams(...))` — 버전에 따라 다르다)를 pub 캐시 소스나 README에서 확인한 뒤 Step 3을 그 시그니처로 작성한다.

- [ ] **Step 2: 순수 CSV 빌더**

`lib/features/stats/csv_export.dart`:
```dart
import 'package:ppyu_budget/features/ledger/models/transaction.dart';

String buildTransactionsCsv({
  required List<LedgerTransaction> transactions,
  required Map<String, String> accountNames,
  required Map<String, String> categoryNames,
  required Map<String, String> tagNames,
  required Map<String, String> memberNicknames,
}) {
  final buffer = StringBuffer('날짜,구분,금액,계좌,카테고리,사용처,메모,태그,입력자\n');
  for (final t in transactions) {
    final tagLabel = t.tagIds.map((id) => tagNames[id] ?? '').where((n) => n.isNotEmpty).join('/');
    final fields = [
      t.occurredAt.toLocal().toIso8601String(),
      t.type == 'expense' ? '지출' : '수입',
      t.amount.toString(),
      accountNames[t.accountId] ?? '',
      categoryNames[t.categoryId] ?? '',
      t.merchant ?? '',
      t.memo ?? '',
      tagLabel,
      memberNicknames[t.memberId] ?? '가족 구성원',
    ];
    buffer.writeln(fields.map(_csvField).join(','));
  }
  return buffer.toString();
}

String _csvField(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}
```

- [ ] **Step 3: 순수 함수 테스트**

`test/features/stats/csv_export_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/stats/csv_export.dart';

void main() {
  test('builds a CSV row per transaction with resolved names', () {
    final csv = buildTransactionsCsv(
      transactions: [
        LedgerTransaction(
          id: 't1',
          accountId: 'a1',
          categoryId: 'c1',
          memberId: 'm1',
          type: 'expense',
          amount: 12000,
          occurredAt: DateTime.utc(2026, 8, 26, 14, 33),
          source: 'manual',
          merchant: '스타벅스',
          tagIds: const ['tag1'],
        ),
      ],
      accountNames: const {'a1': '신한카드'},
      categoryNames: const {'c1': '식비'},
      tagNames: const {'tag1': '카페'},
      memberNicknames: const {'m1': '민수'},
    );

    final lines = csv.trim().split('\n');
    expect(lines, hasLength(2));
    expect(lines[1], contains('지출'));
    expect(lines[1], contains('12000'));
    expect(lines[1], contains('신한카드'));
    expect(lines[1], contains('식비'));
    expect(lines[1], contains('스타벅스'));
    expect(lines[1], contains('카페'));
    expect(lines[1], contains('민수'));
  });

  test('quotes a field containing a comma', () {
    final csv = buildTransactionsCsv(
      transactions: [
        LedgerTransaction(
          id: 't1',
          accountId: 'a1',
          categoryId: 'c1',
          memberId: 'm1',
          type: 'expense',
          amount: 1000,
          occurredAt: DateTime.utc(2026, 8, 26),
          source: 'manual',
          memo: '점심, 저녁',
        ),
      ],
      accountNames: const {'a1': '카드'},
      categoryNames: const {'c1': '식비'},
      tagNames: const {},
      memberNicknames: const {},
    );

    expect(csv, contains('"점심, 저녁"'));
  });
}
```

- [ ] **Step 4: 테스트 실행**

Run: `flutter test test/features/stats/csv_export_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: 통계 화면에 내보내기 버튼 연결**

`stats_screen.dart`에 추가:
```dart
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/tag_management_screen.dart' show tagRepository;
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
import 'package:ppyu_budget/features/stats/csv_export.dart';
```

`_StatsScreenState`에 메서드 추가:
```dart
  bool _exporting = false;

  Future<void> _exportCsv() async {
    setState(() => _exporting = true);
    try {
      final allTransactions = await transactionRepository.list(widget.householdId);
      final monthTransactions = allTransactions
          .where((t) =>
              t.occurredAt.toLocal().year == _month.year &&
              t.occurredAt.toLocal().month == _month.month)
          .toList();
      if (monthTransactions.isEmpty) {
        if (mounted) setState(() => _error = '내보낼 거래가 없어요');
        return;
      }
      final accounts = await accountRepository.list(widget.householdId);
      final categories = await categoryRepository.list(widget.householdId);
      final tags = await tagRepository.list(widget.householdId);
      final nicknames = await householdRepository.nicknamesByMemberId(widget.householdId);

      final csv = buildTransactionsCsv(
        transactions: monthTransactions,
        accountNames: {for (final a in accounts) a.id: a.name},
        categoryNames: {for (final c in categories) c.id: c.name},
        tagNames: {for (final t in tags) t.id: t.name},
        memberNicknames: nicknames,
      );

      // TODO(implementer): share `csv` via the verified share_plus API from Step 1,
      // as an XFile named '${_month.year}-${_month.month}-transactions.csv',
      // mimeType 'text/csv'.
    } catch (e) {
      if (mounted) setState(() => _error = 'CSV 내보내기에 실패했어요');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
```

> 이 스텝의 `TODO`는 이 계획 전체에서 유일하게 허용되는 자리표시자다 — Step 1에서 확인한 실제 `share_plus` API로 구현자가 직접 채운다 (버전별 시그니처 차이 때문에 여기서 고정할 수 없음). 나머지 로직(월별 필터링, 이름 조회, 빈 달 처리)은 전부 확정 코드다.

월 표시 `Row` 아래, `body`의 `Column` children 맨 앞에 버튼 추가:
```dart
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextButton.icon(
                onPressed: _exporting ? null : _exportCsv,
                icon: const Icon(Icons.share),
                label: const Text('CSV 내보내기'),
              ),
            ),
          ),
```

- [ ] **Step 6: 수동 확인**

Run: `flutter analyze`
Expected: TODO 자리(share_plus 호출)를 구현자가 채운 뒤 새 에러 없음

- [ ] **Step 7: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/features/stats/csv_export.dart test/features/stats/csv_export_test.dart lib/features/stats/stats_screen.dart
git commit -m "feat(stats): add CSV export for the selected month via the device share sheet"
```

---

### Task 10: 검색 + 태그 필터 칩 + 입력자 표시 (거래 목록 화면)

**Files:**
- Modify: `lib/features/ledger/transaction_list_screen.dart`

**Interfaces:**
- Consumes: `tagRepository`(Task 3), `LedgerTransaction.tagIds`(Task 4), `householdRepository.nicknamesByMemberId`(Task 6)

- [ ] **Step 1: 검색바 + 태그 필터 + 입력자 표시 추가**

`lib/features/ledger/transaction_list_screen.dart`을 아래로 교체:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
import 'package:ppyu_budget/features/ledger/models/tag.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/tag_management_screen.dart' show tagRepository;
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
  List<Tag>? _tags;
  Map<String, String> _nicknames = {};
  String? _error;
  final _searchController = TextEditingController();
  String _query = '';
  final Set<String> _selectedTagIds = {};

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  Future<void> _load() async {
    try {
      final transactions = await transactionRepository.list(widget.householdId);
      final tags = await tagRepository.list(widget.householdId);
      final nicknames = await householdRepository.nicknamesByMemberId(widget.householdId);
      if (!mounted) return;
      setState(() {
        _transactions = transactions;
        _tags = tags;
        _nicknames = nicknames;
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

  List<LedgerTransaction> _filtered(List<LedgerTransaction> all) {
    return all.where((t) {
      if (_query.isNotEmpty) {
        final haystack = '${t.memo ?? ''} ${t.merchant ?? ''}'.toLowerCase();
        if (!haystack.contains(_query)) return false;
      }
      if (_selectedTagIds.isNotEmpty && !t.tagIds.any(_selectedTagIds.contains)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transactions = _transactions;
    final tags = _tags;
    final filtered = transactions == null ? null : _filtered(transactions);
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(labelText: '메모/사용처 검색', prefixIcon: Icon(Icons.search)),
            ),
          ),
          if (tags != null && tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                spacing: 8,
                children: tags.map((tag) {
                  final selected = _selectedTagIds.contains(tag.id);
                  return FilterChip(
                    label: Text(tag.name),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedTagIds.add(tag.id);
                      } else {
                        _selectedTagIds.remove(tag.id);
                      }
                    }),
                  );
                }).toList(),
              ),
            ),
          Expanded(
            child: filtered == null
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(child: Text('조건에 맞는 거래가 없어요'))
                    : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final t = filtered[i];
                        final sign = t.type == 'expense' ? '-' : '+';
                        return ListTile(
                          leading: t.source == 'notification_auto'
                              ? const Icon(Icons.notifications_active, size: 20)
                              : null,
                          title: Text(t.merchant?.isNotEmpty == true ? t.merchant! : (t.memo ?? '(내용 없음)')),
                          subtitle: Text('${_formatDate(t.occurredAt)} · ${_nicknames[t.memberId] ?? '가족 구성원'}'),
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

- [ ] **Step 2: 수동 확인**

Run: `flutter analyze`
Expected: 새 에러 없음

- [ ] **Step 3: Commit**

```bash
git add lib/features/ledger/transaction_list_screen.dart
git commit -m "feat(ledger): add search, tag filter chips, and member nickname to transaction list"
```
