# blacktable v1 (테이블 코어 + 얇은 계정) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 폰=손패 / TV=테이블 구조로 원카드·도둑잡기를 실물 수준 자유도로 돌릴 수 있는 웹(PWA) 앱의 첫 동작 버전을 만든다.

**Architecture:** Flutter(웹 빌드) 단일 클라이언트가 두 모드(핸드 뷰 / 테이블 뷰)로 동작한다. 백엔드는 Supabase 하나 — Postgres에 상태를 두고, 모든 변경은 `security definer` RPC를 통과하며, 숨김 정보는 RLS + 마스킹 뷰로 강제한다. 클라이언트는 Realtime 통지를 받으면 바뀐 무더기만 다시 읽어 그린다(낙관적 UI는 반응성용, RPC 결과로 정정).

**Tech Stack:** Flutter 3.24+ / Dart 3.5+, `supabase_flutter` ^2.5, `provider` ^6.1 (상태), Supabase CLI(로컬 개발 + 마이그레이션), pgTAP(`supabase test db`), Flutter 표준 `Draggable`/`DragTarget`(게임 엔진 없음).

**Spec:** `docs/superpowers/specs/2026-08-31-blacktable-v1-design.md`

## Global Constraints

- 프로젝트 위치: 저장소 루트의 `blacktable/` 디렉터리. `ppyu_budget/`와 코드·의존성 공유 없음.
- 화폐는 방 한정·휘발성. 방 간 이월·소유·거래·환전 경로를 어떤 형태로도 만들지 않는다. 현금 구매·환전 경로 없음.
- 룰 자동 진행·점수 자동 집계 없음. 프리셋은 "판 세팅"만 한다.
- v1 범위 밖(만들지 않음): 영상통화, 보이스, 텍스트 채팅, 스킨 상점·결제·인벤토리, 네이티브 앱 빌드.
- 방 정원 30석 고정(`seat_index` 0..29). 프리셋 인원: `trump` 2~10, `hwatu` 2~4, `tokens` 1~30 — 서버 `preset_range()` 함수가 진실의 원천, 클라이언트 상수는 UI 미러.
- 재접속 좌석 복구는 로그인(비익명) 사용자만. 게스트는 순간 끊김·재입장 모두 새 좌석.
- 모든 상태 변경은 RPC 경유. 클라이언트는 `cards` 원본 테이블에 직접 접근하지 않는다(`cards_view`/`pile_projection`만).
- 커밋은 각 Task의 마지막 Step에서. 커밋 메시지 말미:
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`

---

## File Structure

### 백엔드 (`blacktable/supabase/`)

| 파일 | 책임 |
|---|---|
| `supabase/config.toml` | 로컬 Supabase 설정(포트, auth, 익명 로그인 허용) |
| `supabase/migrations/0001_schema.sql` | 테이블 6개 + 인덱스 + `preset_range()` + RLS 활성화(정책 없음) |
| `supabase/migrations/0002_views.sql` | `cards_view`, `pile_projection` 마스킹 뷰 |
| `supabase/migrations/0003_policies.sql` | RLS 정책(profiles/rooms/seats/piles/table_viewers select, cards 잠금) |
| `supabase/migrations/0004_rpc_room.sql` | `create_room` `join_room` `join_as_table` `leave_room` `close_room` `transfer_host` `claim_host` |
| `supabase/migrations/0005_rpc_cards.sql` | `deal` `draw` `move_cards` `shuffle_pile` `set_pile_spread` `create_table_pile` `set_chips` |
| `supabase/migrations/0006_rpc_profile_cleanup.sql` | `update_profile` + `sweep_abandoned_rooms()` + pg_cron 스케줄 |
| `supabase/tests/*.sql` | pgTAP 테스트, 파일당 한 관심사 |

### 클라이언트 (`blacktable/lib/`)

| 파일 | 책임 |
|---|---|
| `lib/main.dart` | 부트스트랩(Supabase 초기화, 익명 세션 보장), 라우팅 |
| `lib/env.dart` | Supabase URL/anonKey (컴파일 타임 `--dart-define`) |
| `lib/models.dart` | `Room` `Seat` `PileView` `CardView` `RoomState` 불변 모델 + `fromMap` |
| `lib/presets.dart` | 프리셋 상수(덱 구성, 기본 분배, 인원 범위) — UI용 미러 |
| `lib/auth_service.dart` | 익명 세션 보장, 구글 OAuth 로그인/로그아웃 |
| `lib/room_repository.dart` | RPC 래퍼 + Realtime 구독 + 무더기 단위 리페치 → `Stream<RoomState>` |
| `lib/room_controller.dart` | `ChangeNotifier`. 현재 `RoomState` 보유, repository 스트림 구독, 낙관적 갱신·정정 |
| `lib/screens/landing_screen.dart` | 방 만들기 / 코드로 참가 / 구글 로그인 |
| `lib/screens/create_room_screen.dart` | 프리셋·화폐 선택 → `create_room` → 코드/QR 표시 |
| `lib/screens/hand_screen.dart` | 핸드 뷰(내 손패 부채꼴, 드래그로 내기/회수, 펼침 토글, 칩, 방장 메뉴) |
| `lib/screens/table_screen.dart` | 테이블 뷰(공용 무더기, 좌석별 뒷면 수·칩, presence 배지) |
| `lib/screens/profile_screen.dart` | 닉네임 + 카드/아바타 스킨 선택 |
| `lib/widgets/card_fan.dart` | 부채꼴 손패 위젯 + 드래그 소스 |
| `lib/widgets/pile_widget.dart` | 무더기 렌더(겹침/펼침, 뒷면 수) + `DragTarget` |
| `lib/widgets/reconnecting_overlay.dart` | 연결 끊김 표시 |
| `test/*` | 위젯·통합 테스트 |
| `web/manifest.json`, `web/index.html` | PWA 매니페스트 |

---

## Task 1: Supabase 스캐폴드 + 스키마 마이그레이션

**Files:**
- Create: `blacktable/supabase/config.toml` (via `supabase init`)
- Create: `blacktable/supabase/migrations/0001_schema.sql`
- Test: `blacktable/supabase/tests/0001_schema_test.sql`

**Interfaces:**
- Produces: 테이블 `profiles, rooms, seats, table_viewers, piles, cards`; 함수 `preset_range(text) returns int4range`.

- [ ] **Step 1: 프로젝트 폴더 + Supabase 초기화**

```bash
mkdir -p blacktable && cd blacktable
supabase init
# config.toml 에서 [auth] 아래 확인/설정:
#   enable_anonymous_sign_ins = true
```

- [ ] **Step 2: 실패하는 테스트 작성** — `blacktable/supabase/tests/0001_schema_test.sql`

```sql
begin;
select plan(8);
select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'rooms', 'rooms table exists');
select has_table('public', 'seats', 'seats table exists');
select has_table('public', 'table_viewers', 'table_viewers table exists');
select has_table('public', 'piles', 'piles table exists');
select has_table('public', 'cards', 'cards table exists');
select has_function('public', 'preset_range', array['text'], 'preset_range fn exists');
select is( (select upper(preset_range('trump')::text)), '[2,11)', 'trump range 2..10 inclusive' );
select * from finish();
rollback;
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `supabase db reset && supabase test db`
Expected: FAIL — 테이블/함수 없음.

- [ ] **Step 4: 마이그레이션 작성** — `blacktable/supabase/migrations/0001_schema.sql`

```sql
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  card_skin text not null default 'classic',
  avatar_skin text not null default 'default',
  created_at timestamptz not null default now()
);

create table rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_id uuid not null references auth.users(id),
  preset_key text not null check (preset_key in ('trump','hwatu','tokens')),
  status text not null default 'lobby' check (status in ('lobby','playing','closed')),
  currency_label text,
  starting_chips int,
  created_at timestamptz not null default now()
);

create table seats (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  is_guest boolean not null default true,
  seat_index int not null check (seat_index between 0 and 29),
  nickname text not null,
  chips int not null default 0 check (chips >= 0),
  connected boolean not null default true,
  last_seen timestamptz not null default now(),
  unique (room_id, user_id),
  unique (room_id, seat_index)
);

create table table_viewers (
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  last_seen timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table piles (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  kind text not null check (kind in ('deck','discard','hand','table_free','named')),
  owner_seat_id uuid references seats(id) on delete set null,
  label text,
  x real, y real, z int,
  spread boolean not null default false
);

create table cards (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  pile_id uuid not null references piles(id) on delete cascade,
  card_code text not null,
  face_up boolean not null default false,
  sort_order int not null
);

create index on seats (room_id);
create index on piles (room_id);
create index on cards (pile_id);
create index on cards (room_id);

create function preset_range(p_key text) returns int4range
  language sql immutable as $$
  select case p_key
    when 'trump' then int4range(2, 10, '[]')
    when 'hwatu' then int4range(2, 4, '[]')
    when 'tokens' then int4range(1, 30, '[]')
  end $$;

alter table profiles      enable row level security;
alter table rooms         enable row level security;
alter table seats         enable row level security;
alter table table_viewers enable row level security;
alter table piles         enable row level security;
alter table cards         enable row level security;
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `supabase db reset && supabase test db`
Expected: PASS (8/8).

- [ ] **Step 6: 커밋**

```bash
git add blacktable/supabase
git commit -m "feat(blacktable): supabase scaffold + schema migration"
```

---

## Task 2: 마스킹 뷰 (`cards_view`, `pile_projection`)

**Files:**
- Create: `blacktable/supabase/migrations/0002_views.sql`
- Test: `blacktable/supabase/tests/0002_masking_test.sql`

**Interfaces:**
- Consumes: Task 1 테이블.
- Produces: 뷰 `cards_view(id, room_id, pile_id, face_up, sort_order, card_code)` — `card_code`는 `face_up` 이거나 요청자 소유 손패일 때만 실제값, 아니면 null. 뷰 `pile_projection(pile_id, room_id, kind, owner_seat_id, label, x, y, z, spread, card_count, visible)` — `visible`은 `spread` 또는 소유자면 true.

- [ ] **Step 1: 실패하는 테스트 작성** — `blacktable/supabase/tests/0002_masking_test.sql`

```sql
begin;
select plan(4);

-- fixture: 두 유저, 한 방, 두 손패, 카드 각 1장(엎힘)
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'),
                                    ('22222222-2222-2222-2222-222222222222');
insert into rooms (id, code, host_id, preset_key)
  values ('aaaaaaaa-0000-0000-0000-000000000000','ABC234',
          '11111111-1111-1111-1111-111111111111','trump');
insert into seats (id, room_id, user_id, seat_index, nickname) values
  ('5ea70001-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111',0,'A'),
  ('5ea70002-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222',1,'B');
insert into piles (id, room_id, kind, owner_seat_id, spread) values
  ('91100001-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','hand','5ea70001-0000-0000-0000-000000000000', false),
  ('91100002-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','hand','5ea70002-0000-0000-0000-000000000000', false);
insert into cards (room_id, pile_id, card_code, face_up, sort_order) values
  ('aaaaaaaa-0000-0000-0000-000000000000','91100001-0000-0000-0000-000000000000','AS', false, 0),
  ('aaaaaaaa-0000-0000-0000-000000000000','91100002-0000-0000-0000-000000000000','KH', false, 0);

-- act as user A
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

select is( (select card_code from cards_view where pile_id='91100001-0000-0000-0000-000000000000'),
           'AS', 'A sees own face-down card' );
select is( (select card_code from cards_view where pile_id='91100002-0000-0000-0000-000000000000'),
           null, 'A cannot see B face-down card' );
select is( (select card_count from pile_projection where pile_id='91100002-0000-0000-0000-000000000000'),
           1::bigint, 'count is visible' );
select is( (select visible from pile_projection where pile_id='91100002-0000-0000-0000-000000000000'),
           false, 'B hand not spread -> not visible to A' );

select * from finish();
rollback;
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `supabase db reset && supabase test db`
Expected: FAIL — `cards_view` 없음.

- [ ] **Step 3: 마이그레이션 작성** — `blacktable/supabase/migrations/0002_views.sql`

```sql
create view cards_view
with (security_invoker = true) as
select
  c.id, c.room_id, c.pile_id, c.face_up, c.sort_order,
  case
    when c.face_up then c.card_code
    when p.kind = 'hand' and s.user_id = auth.uid() then c.card_code
    else null
  end as card_code
from cards c
join piles p on p.id = c.pile_id
left join seats s on s.id = p.owner_seat_id
where exists (select 1 from seats me
              where me.room_id = c.room_id and me.user_id = auth.uid())
   or exists (select 1 from table_viewers tv
              where tv.room_id = c.room_id and tv.user_id = auth.uid());

create view pile_projection
with (security_invoker = true) as
select
  p.id as pile_id, p.room_id, p.kind, p.owner_seat_id, p.label,
  p.x, p.y, p.z, p.spread,
  (select count(*) from cards c where c.pile_id = p.id) as card_count,
  (p.spread or exists (select 1 from seats s
     where s.id = p.owner_seat_id and s.user_id = auth.uid())) as visible
from piles p
where exists (select 1 from seats me
              where me.room_id = p.room_id and me.user_id = auth.uid())
   or exists (select 1 from table_viewers tv
              where tv.room_id = p.room_id and tv.user_id = auth.uid());

grant select on cards_view, pile_projection to authenticated;
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `supabase db reset && supabase test db`
Expected: PASS (4/4).

- [ ] **Step 5: 커밋**

```bash
git add blacktable/supabase
git commit -m "feat(blacktable): masking views for hidden cards and pile counts"
```

---

## Task 3: RLS 정책

**Files:**
- Create: `blacktable/supabase/migrations/0003_policies.sql`
- Test: `blacktable/supabase/tests/0003_rls_test.sql`

**Interfaces:**
- Consumes: Task 1 테이블.
- Produces: `profiles` 본인 행 select/update; `rooms`/`seats`/`piles`/`table_viewers` 은 방 소속(seat 또는 table_viewer)만 select; `cards` 원본은 클라이언트 정책 없음(= authenticated 접근 불가, service_role/`security definer` 함수만).

- [ ] **Step 1: 실패하는 테스트 작성** — `blacktable/supabase/tests/0003_rls_test.sql`

```sql
begin;
select plan(3);

insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'),
                                    ('33333333-3333-3333-3333-333333333333');
insert into rooms (id, code, host_id, preset_key)
  values ('aaaaaaaa-0000-0000-0000-000000000000','ABC234',
          '11111111-1111-1111-1111-111111111111','trump');
insert into seats (id, room_id, user_id, seat_index, nickname) values
  ('5ea70001-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111',0,'A');
insert into piles (id, room_id, kind) values
  ('91100001-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','deck');
insert into cards (room_id, pile_id, card_code, face_up, sort_order) values
  ('aaaaaaaa-0000-0000-0000-000000000000','91100001-0000-0000-0000-000000000000','AS', false, 0);

set local role authenticated;
-- 방에 없는 유저 3
select set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
select is( (select count(*)::int from rooms where id='aaaaaaaa-0000-0000-0000-000000000000'),
           0, 'non-member cannot see room' );
select is( (select count(*)::int from cards),
           0, 'authenticated cannot read cards base table at all' );
-- 방 멤버 1
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select is( (select count(*)::int from rooms where id='aaaaaaaa-0000-0000-0000-000000000000'),
           1, 'member can see room' );

select * from finish();
rollback;
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `supabase db reset && supabase test db`
Expected: FAIL — 정책 없어 `rooms` 가 전부 안 보이거나(둘째·셋째 단언 엇갈림). 셋째 단언에서 FAIL.

- [ ] **Step 3: 마이그레이션 작성** — `blacktable/supabase/migrations/0003_policies.sql`

```sql
-- helper: 현재 유저가 방 소속(좌석 또는 테이블뷰)인가
create function is_room_participant(p_room_id uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from seats where room_id = p_room_id and user_id = auth.uid())
      or exists (select 1 from table_viewers where room_id = p_room_id and user_id = auth.uid());
$$;

create policy profiles_self_select on profiles for select using (id = auth.uid());
create policy profiles_self_upsert on profiles for insert with check (id = auth.uid());
create policy profiles_self_update on profiles for update using (id = auth.uid());

create policy rooms_member_select on rooms for select using (is_room_participant(id));
create policy seats_member_select on seats for select using (is_room_participant(room_id));
create policy piles_member_select on piles for select using (is_room_participant(room_id));
create policy tv_member_select on table_viewers for select using (is_room_participant(room_id));

-- cards: 클라이언트 정책을 만들지 않는다. RLS on + 정책 0 = authenticated 접근 불가.
-- 모든 읽기는 cards_view, 모든 쓰기는 security definer RPC.
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `supabase db reset && supabase test db`
Expected: PASS (3/3).

- [ ] **Step 5: 커밋**

```bash
git add blacktable/supabase
git commit -m "feat(blacktable): RLS policies (member-scoped reads, cards locked)"
```

---

## Task 4: 방 생명주기 RPC

**Files:**
- Create: `blacktable/supabase/migrations/0004_rpc_room.sql`
- Test: `blacktable/supabase/tests/0004_rpc_room_test.sql`

**Interfaces:**
- Consumes: Task 1~3.
- Produces:
  - `create_room(p_preset_key text, p_nickname text, p_currency_label text default null, p_starting_chips int default null) returns table(room_id uuid, code text)`
  - `join_room(p_code text, p_nickname text) returns uuid` (room_id 반환)
  - `join_as_table(p_code text) returns uuid`
  - `leave_room(p_room_id uuid) returns void`
  - `close_room(p_room_id uuid) returns void`
  - `transfer_host(p_room_id uuid, p_to_seat_id uuid) returns void`
  - `claim_host(p_room_id uuid) returns void`

- [ ] **Step 1: 실패하는 테스트 작성** — `blacktable/supabase/tests/0004_rpc_room_test.sql`

```sql
begin;
select plan(6);
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'),
                                    ('22222222-2222-2222-2222-222222222222'),
                                    ('33333333-3333-3333-3333-333333333333');

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select lives_ok($$ select create_room('trump','Host') $$, 'host can create room');

-- code 조회
select set_config('x.code', (select code from rooms limit 1), false);

select set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select lives_ok($$ select join_room(current_setting('x.code'),'Bob') $$, 'guest can join');
select is( (select count(*)::int from seats), 2, 'two seats' );

-- 정원 초과: seat_index 는 0..29 이므로 31번째 join 은 실패해야 한다 (별도 유저 없이 개념 검증은 생략)
-- 방장 위임
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select lives_ok($$ select transfer_host(
    (select id from rooms limit 1),
    (select id from seats where seat_index=1)) $$, 'host can transfer');
select is( (select host_id from rooms limit 1),
           '22222222-2222-2222-2222-222222222222', 'host changed' );

-- 비방장은 위임 불가
select set_config('request.jwt.claims','{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
select throws_ok($$ select transfer_host((select id from rooms limit 1),
                    (select id from seats where seat_index=0)) $$,
                 'P0001', 'not host', 'non-host cannot transfer');

select * from finish();
rollback;
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `supabase db reset && supabase test db`
Expected: FAIL — 함수 없음.

- [ ] **Step 3: 마이그레이션 작성** — `blacktable/supabase/migrations/0004_rpc_room.sql`

```sql
create or replace function create_room(
  p_preset_key text, p_nickname text,
  p_currency_label text default null, p_starting_chips int default null)
returns table(room_id uuid, code text)
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_code text; v_room uuid;
        v_guest boolean := coalesce((auth.jwt()->>'is_anonymous')::boolean, false);
begin
  if v_uid is null then raise exception 'auth required'; end if;
  if p_preset_key not in ('trump','hwatu','tokens') then raise exception 'bad preset'; end if;
  loop
    v_code := translate(upper(substr(md5(gen_random_uuid()::text),1,6)),'OIL01','PQRS9');
    exit when not exists (select 1 from rooms where rooms.code = v_code);
  end loop;
  insert into rooms(code, host_id, preset_key, currency_label, starting_chips)
    values (v_code, v_uid, p_preset_key, p_currency_label, p_starting_chips)
    returning id into v_room;
  insert into seats(room_id, user_id, is_guest, seat_index, nickname, chips)
    values (v_room, v_uid, v_guest, 0, p_nickname, coalesce(p_starting_chips,0));
  insert into piles(room_id, kind, label) values (v_room,'deck','Deck'),(v_room,'discard','Discard');
  return query select v_room, v_code;
end $$;

create or replace function join_room(p_code text, p_nickname text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_room uuid; v_guest boolean := coalesce((auth.jwt()->>'is_anonymous')::boolean,false);
        v_existing uuid; v_next int; v_chips int;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  select id, starting_chips into v_room, v_chips from rooms where code = upper(p_code) and status <> 'closed';
  if v_room is null then raise exception 'no such room'; end if;
  -- 로그인 사용자 재바인딩
  select id into v_existing from seats where room_id = v_room and user_id = v_uid;
  if v_existing is not null then
    update seats set connected = true, last_seen = now() where id = v_existing;
    return v_room;
  end if;
  select coalesce(min(g.i),0) into v_next
    from generate_series(0,29) g(i)
    where not exists (select 1 from seats where room_id = v_room and seat_index = g.i);
  if v_next is null then raise exception 'room full'; end if;
  insert into seats(room_id, user_id, is_guest, seat_index, nickname, chips)
    values (v_room, v_uid, v_guest, v_next, p_nickname, coalesce(v_chips,0));
  return v_room;
end $$;

create or replace function join_as_table(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_room uuid;
begin
  if v_uid is null then raise exception 'auth required'; end if;
  select id into v_room from rooms where code = upper(p_code) and status <> 'closed';
  if v_room is null then raise exception 'no such room'; end if;
  insert into table_viewers(room_id, user_id) values (v_room, v_uid)
    on conflict (room_id, user_id) do update set last_seen = now();
  return v_room;
end $$;

create or replace function close_room(p_room_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from rooms where id = p_room_id and host_id = auth.uid()) then
    raise exception 'not host';
  end if;
  delete from rooms where id = p_room_id;  -- CASCADE
end $$;

create or replace function transfer_host(p_room_id uuid, p_to_seat_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_to uuid;
begin
  if not exists (select 1 from rooms where id = p_room_id and host_id = auth.uid()) then
    raise exception 'not host';
  end if;
  select user_id into v_to from seats where id = p_to_seat_id and room_id = p_room_id;
  if v_to is null then raise exception 'bad seat'; end if;
  update rooms set host_id = v_to where id = p_room_id;
end $$;

create or replace function claim_host(p_room_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_host_seat seats;
begin
  if not exists (select 1 from seats where room_id = p_room_id and user_id = auth.uid()) then
    raise exception 'not in room';
  end if;
  select s.* into v_host_seat from seats s join rooms r on r.id = s.room_id
    where r.id = p_room_id and s.user_id = r.host_id;
  if v_host_seat.connected and v_host_seat.last_seen > now() - interval '2 minutes' then
    raise exception 'host still active';
  end if;
  update rooms set host_id = auth.uid() where id = p_room_id;
end $$;

create or replace function leave_room(p_room_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_seat seats; v_is_host boolean;
        v_named uuid; v_next_host uuid;
begin
  select * into v_seat from seats where room_id = p_room_id and user_id = v_uid;
  if v_seat.id is null then
    delete from table_viewers where room_id = p_room_id and user_id = v_uid;
    return;
  end if;
  select (host_id = v_uid) into v_is_host from rooms where id = p_room_id;

  if v_seat.is_guest then
    -- 손패를 named 무더기로 이관(엎음)
    if exists (select 1 from piles where kind='hand' and owner_seat_id = v_seat.id) then
      insert into piles(room_id, kind, label, spread)
        values (p_room_id, 'named', v_seat.nickname || ' (나감)', false)
        returning id into v_named;
      update cards set pile_id = v_named, face_up = false
        where pile_id in (select id from piles where kind='hand' and owner_seat_id = v_seat.id);
      delete from piles where kind='hand' and owner_seat_id = v_seat.id;
    end if;
    delete from seats where id = v_seat.id;
  else
    update seats set connected = false, last_seen = now() where id = v_seat.id;
  end if;

  if v_is_host then
    select user_id into v_next_host from seats
      where room_id = p_room_id and connected = true and user_id <> v_uid
      order by seat_index limit 1;
    if v_next_host is null then
      delete from rooms where id = p_room_id;
    else
      update rooms set host_id = v_next_host where id = p_room_id;
    end if;
  end if;
end $$;
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `supabase db reset && supabase test db`
Expected: PASS (6/6).

- [ ] **Step 5: 커밋**

```bash
git add blacktable/supabase
git commit -m "feat(blacktable): room lifecycle RPCs (create/join/leave/host transfer)"
```

---

## Task 5: 카드 액션 RPC

**Files:**
- Create: `blacktable/supabase/migrations/0005_rpc_cards.sql`
- Test: `blacktable/supabase/tests/0005_rpc_cards_test.sql`

**Interfaces:**
- Consumes: Task 1~4. `preset_range()`.
- Produces:
  - `deal(p_room_id uuid, p_from_pile_id uuid, p_counts jsonb) returns void` — `p_counts` = `{"<seat_id>": <n>, ...}`. 방장만. 대상 좌석 수가 `preset_range(preset_key)` 밖이면 예외.
  - `draw(p_room_id uuid, p_from_pile_id uuid) returns void` — 맨 위(max sort_order) 1장 → 내 손패.
  - `move_cards(p_card_ids uuid[], p_to_pile_id uuid, p_face_up boolean default null) returns void` — 출발이 내 손패/discard/table_free/named 인 카드만. 행 수 불일치 시 `conflict`.
  - `shuffle_pile(p_pile_id uuid) returns void`
  - `set_pile_spread(p_pile_id uuid, p_spread boolean) returns void`
  - `create_table_pile(p_room_id uuid, p_x real, p_y real, p_label text default null) returns uuid`
  - `set_chips(p_seat_id uuid, p_delta int) returns void`
- 공통 헬퍼: `_ensure_hand(p_room_id uuid, p_uid uuid) returns uuid` — 호출자의 hand 무더기 id, 없으면 생성.

- [ ] **Step 1: 실패하는 테스트 작성** — `blacktable/supabase/tests/0005_rpc_cards_test.sql`

```sql
begin;
select plan(6);
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111'),
                                    ('22222222-2222-2222-2222-222222222222');
insert into rooms (id, code, host_id, preset_key, status)
  values ('aaaaaaaa-0000-0000-0000-000000000000','ABC234',
          '11111111-1111-1111-1111-111111111111','trump','playing');
insert into seats (id, room_id, user_id, seat_index, nickname, chips) values
  ('5ea70001-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111',0,'A',10),
  ('5ea70002-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222',1,'B',10);
insert into piles (id, room_id, kind, owner_seat_id) values
  ('h1000001-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','hand','5ea70001-0000-0000-0000-000000000000'),
  ('h1000002-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','hand','5ea70002-0000-0000-0000-000000000000');
insert into piles (id, room_id, kind, label) values
  ('d1000000-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','discard','Discard');
insert into cards (id, room_id, pile_id, card_code, face_up, sort_order) values
  ('c0000001-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','h1000001-0000-0000-0000-000000000000','AS',false,0),
  ('c0000002-0000-0000-0000-000000000000','aaaaaaaa-0000-0000-0000-000000000000','h1000002-0000-0000-0000-000000000000','KH',false,0);

set local role authenticated;
-- A: 자기 카드 내기 OK
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select lives_ok($$ select move_cards(array['c0000001-0000-0000-0000-000000000000']::uuid[],
                                     'd1000000-0000-0000-0000-000000000000', true) $$,
                'A plays own card');
select is((select pile_id from cards where id='c0000001-0000-0000-0000-000000000000'),
          'd1000000-0000-0000-0000-000000000000','card moved to discard');

-- A: B의 카드 내기 거부
select throws_ok($$ select move_cards(array['c0000002-0000-0000-0000-000000000000']::uuid[],
                                      'd1000000-0000-0000-0000-000000000000', true) $$,
                 'P0001','conflict','A cannot move B card');

-- set_chips: 음수 결과 거부
select throws_ok($$ select set_chips('5ea70001-0000-0000-0000-000000000000', -999) $$,
                 '23514', null, 'chips cannot go negative');

-- deal: 프리셋 인원 범위(trump 2..10) - 1명만 대상이면 거부
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select throws_ok($$ select deal('aaaaaaaa-0000-0000-0000-000000000000',
   'd1000000-0000-0000-0000-000000000000',
   '{"5ea70001-0000-0000-0000-000000000000": 3}'::jsonb) $$,
   'P0001','player count out of preset range','deal rejects 1-player trump');

-- 비방장은 deal 불가
select set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select throws_ok($$ select deal('aaaaaaaa-0000-0000-0000-000000000000',
   'd1000000-0000-0000-0000-000000000000',
   '{"5ea70001-0000-0000-0000-000000000000":1,"5ea70002-0000-0000-0000-000000000000":1}'::jsonb) $$,
   'P0001','not host','non-host cannot deal');

select * from finish();
rollback;
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `supabase db reset && supabase test db`
Expected: FAIL — 함수 없음.

- [ ] **Step 3: 마이그레이션 작성** — `blacktable/supabase/migrations/0005_rpc_cards.sql`

```sql
create or replace function _ensure_hand(p_room_id uuid, p_uid uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_seat uuid; v_pile uuid;
begin
  select id into v_seat from seats where room_id = p_room_id and user_id = p_uid;
  if v_seat is null then raise exception 'not in room'; end if;
  select id into v_pile from piles where room_id = p_room_id and kind='hand' and owner_seat_id = v_seat;
  if v_pile is null then
    insert into piles(room_id, kind, owner_seat_id, label, spread)
      values (p_room_id,'hand',v_seat,null,false) returning id into v_pile;
  end if;
  return v_pile;
end $$;

create or replace function move_cards(p_card_ids uuid[], p_to_pile_id uuid, p_face_up boolean default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_room uuid; v_allowed uuid[]; v_base int; v_moved int;
begin
  select room_id into v_room from piles where id = p_to_pile_id;
  if v_room is null then raise exception 'bad pile'; end if;
  if not exists (select 1 from seats where room_id = v_room and user_id = v_uid) then
    raise exception 'not in room';
  end if;
  select array_agg(p.id) into v_allowed
    from piles p left join seats s on s.id = p.owner_seat_id
    where p.room_id = v_room
      and ( (p.kind='hand' and s.user_id = v_uid) or p.kind in ('discard','table_free','named') );
  select coalesce(max(sort_order),0) into v_base from cards where pile_id = p_to_pile_id;
  with ord as (select id, row_number() over () as rn
               from unnest(p_card_ids) as id)
  update cards c
     set pile_id = p_to_pile_id,
         face_up = coalesce(p_face_up, c.face_up),
         sort_order = v_base + ord.rn
    from ord
   where c.id = ord.id
     and c.pile_id = any(v_allowed);
  get diagnostics v_moved = row_count;
  if v_moved <> coalesce(array_length(p_card_ids,1),0) then
    raise exception 'conflict';
  end if;
end $$;

create or replace function draw(p_room_id uuid, p_from_pile_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_hand uuid; v_card uuid;
begin
  if not exists (select 1 from piles where id = p_from_pile_id and room_id = p_room_id) then
    raise exception 'bad pile';
  end if;
  v_hand := _ensure_hand(p_room_id, v_uid);
  select id into v_card from cards where pile_id = p_from_pile_id
    order by sort_order desc limit 1;
  if v_card is null then raise exception 'pile empty'; end if;
  update cards set pile_id = v_hand, face_up = false,
    sort_order = (select coalesce(max(sort_order),0)+1 from cards where pile_id = v_hand)
    where id = v_card;
end $$;

create or replace function deal(p_room_id uuid, p_from_pile_id uuid, p_counts jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_preset text; v_rng int4range; v_n int; k text; v_hand uuid; i int; v_card uuid; v_seat uuid;
begin
  select preset_key into v_preset from rooms where id = p_room_id and host_id = auth.uid();
  if v_preset is null then raise exception 'not host'; end if;
  v_rng := preset_range(v_preset);
  v_n := (select count(*) from jsonb_object_keys(p_counts));
  if not (v_n <@ v_rng) then raise exception 'player count out of preset range'; end if;
  for k in select jsonb_object_keys(p_counts) loop
    v_seat := k::uuid;
    if not exists (select 1 from seats where id = v_seat and room_id = p_room_id) then
      raise exception 'bad seat in counts';
    end if;
    select id into v_hand from piles where room_id = p_room_id and kind='hand' and owner_seat_id = v_seat;
    if v_hand is null then
      insert into piles(room_id, kind, owner_seat_id, spread)
        values (p_room_id,'hand',v_seat,false) returning id into v_hand;
    end if;
    for i in 1..(p_counts->>k)::int loop
      select id into v_card from cards where pile_id = p_from_pile_id order by sort_order desc limit 1;
      if v_card is null then raise exception 'deck ran out'; end if;
      update cards set pile_id = v_hand, face_up = false,
        sort_order = (select coalesce(max(sort_order),0)+1 from cards where pile_id = v_hand)
        where id = v_card;
    end loop;
  end loop;
  update rooms set status = 'playing' where id = p_room_id;
end $$;

create or replace function shuffle_pile(p_pile_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_kind text; v_owner_uid uuid;
begin
  select p.room_id, p.kind, s.user_id into v_room, v_kind, v_owner_uid
    from piles p left join seats s on s.id = p.owner_seat_id where p.id = p_pile_id;
  if v_room is null then raise exception 'bad pile'; end if;
  if not ( exists (select 1 from rooms where id = v_room and host_id = auth.uid())
           or v_owner_uid = auth.uid()
           or v_kind in ('discard','table_free') ) then
    raise exception 'not allowed';
  end if;
  update cards set sort_order = r.rn
    from (select id, row_number() over (order by random()) as rn
          from cards where pile_id = p_pile_id) r
   where cards.id = r.id;
end $$;

create or replace function set_pile_spread(p_pile_id uuid, p_spread boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_owner_uid uuid; v_kind text;
begin
  select p.room_id, s.user_id, p.kind into v_room, v_owner_uid, v_kind
    from piles p left join seats s on s.id = p.owner_seat_id where p.id = p_pile_id;
  if v_room is null then raise exception 'bad pile'; end if;
  if not ( v_owner_uid = auth.uid()
           or exists (select 1 from rooms where id = v_room and host_id = auth.uid())
           or v_kind in ('discard','table_free','named') ) then
    raise exception 'not allowed';
  end if;
  update piles set spread = p_spread where id = p_pile_id;
end $$;

create or replace function create_table_pile(p_room_id uuid, p_x real, p_y real, p_label text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not exists (select 1 from seats where room_id = p_room_id and user_id = auth.uid()) then
    raise exception 'not in room';
  end if;
  insert into piles(room_id, kind, label, x, y, spread)
    values (p_room_id,'table_free',p_label,p_x,p_y,true) returning id into v_id;
  return v_id;
end $$;

create or replace function set_chips(p_seat_id uuid, p_delta int)
returns void language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_target_uid uuid;
begin
  select room_id, user_id into v_room, v_target_uid from seats where id = p_seat_id;
  if v_room is null then raise exception 'bad seat'; end if;
  if not ( v_target_uid = auth.uid()
           or exists (select 1 from rooms where id = v_room and host_id = auth.uid()) ) then
    raise exception 'not allowed';
  end if;
  update seats set chips = chips + p_delta where id = p_seat_id;  -- chips>=0 CHECK가 음수 거부(23514)
end $$;

grant execute on all functions in schema public to authenticated;
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `supabase db reset && supabase test db`
Expected: PASS (6/6).

- [ ] **Step 5: 동시성 테스트 추가** — 같은 파일에 `plan(6)` → `plan(7)`, 마지막에:

```sql
-- 동시 move: 두 트랜잭션 시뮬레이션은 pgTAP 단일세션에서 불가하므로
-- "출발 pile 이 이미 바뀐 카드"를 move 시도 → conflict 로 근사 검증
select set_config('request.jwt.claims','{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
update cards set pile_id='d1000000-0000-0000-0000-000000000000'
  where id='c0000002-0000-0000-0000-000000000000';  -- 이미 이동됨(다른 사람이 옮긴 상황)
select throws_ok($$ select move_cards(array['c0000002-0000-0000-0000-000000000000']::uuid[],
   'h1000001-0000-0000-0000-000000000000') $$,
   'P0001','conflict','stale source pile -> conflict');
```

- [ ] **Step 6: 재확인 + 커밋**

```bash
supabase db reset && supabase test db
git add blacktable/supabase
git commit -m "feat(blacktable): card action RPCs (deal/draw/move/shuffle/spread/chips)"
```

---

## Task 6: 프로필 RPC + 방 청소 잡

**Files:**
- Create: `blacktable/supabase/migrations/0006_rpc_profile_cleanup.sql`
- Test: `blacktable/supabase/tests/0006_cleanup_test.sql`

**Interfaces:**
- Produces:
  - `update_profile(p_display_name text default null, p_card_skin text default null, p_avatar_skin text default null) returns void` — 비익명만. `profiles` upsert.
  - `sweep_abandoned_rooms() returns int` — 접속 좌석 0이 6시간 이상인 방 삭제, 삭제 수 반환.

- [ ] **Step 1: 실패하는 테스트 작성** — `blacktable/supabase/tests/0006_cleanup_test.sql`

```sql
begin;
select plan(2);
insert into auth.users (id) values ('11111111-1111-1111-1111-111111111111');
insert into rooms (id, code, host_id, preset_key, created_at)
  values ('aaaaaaaa-0000-0000-0000-000000000000','ABC234',
          '11111111-1111-1111-1111-111111111111','trump', now() - interval '2 days');
insert into seats (room_id, user_id, seat_index, nickname, connected, last_seen)
  values ('aaaaaaaa-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111',
          0,'A', false, now() - interval '7 hours');

select is( sweep_abandoned_rooms(), 1, 'abandoned room swept' );
select is( (select count(*)::int from rooms), 0, 'room gone' );
select * from finish();
rollback;
```

- [ ] **Step 2: 실패 확인** — `supabase db reset && supabase test db` → FAIL.

- [ ] **Step 3: 마이그레이션 작성** — `blacktable/supabase/migrations/0006_rpc_profile_cleanup.sql`

```sql
create or replace function update_profile(
  p_display_name text default null, p_card_skin text default null, p_avatar_skin text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then
    raise exception 'login required';
  end if;
  insert into profiles(id, display_name, card_skin, avatar_skin)
    values (v_uid, p_display_name, coalesce(p_card_skin,'classic'), coalesce(p_avatar_skin,'default'))
  on conflict (id) do update set
    display_name = coalesce(p_display_name, profiles.display_name),
    card_skin    = coalesce(p_card_skin, profiles.card_skin),
    avatar_skin  = coalesce(p_avatar_skin, profiles.avatar_skin);
end $$;

create or replace function sweep_abandoned_rooms()
returns int language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  with dead as (
    select r.id from rooms r
    where not exists (
      select 1 from seats s
      where s.room_id = r.id and s.connected = true and s.last_seen > now() - interval '6 hours'
    )
    and r.created_at < now() - interval '6 hours'
  ), del as ( delete from rooms where id in (select id from dead) returning 1 )
  select count(*) into v_count from del;
  return v_count;
end $$;

-- pg_cron 스케줄 (로컬에선 확장이 없을 수 있으니 조건부)
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('blacktable-sweep', '0 4 * * *', 'select sweep_abandoned_rooms()');
  end if;
end $$;
```

- [ ] **Step 4: 통과 확인 + 커밋**

```bash
supabase db reset && supabase test db
git add blacktable/supabase
git commit -m "feat(blacktable): update_profile RPC + abandoned-room sweep"
```

---

## Task 7: Realtime publication 설정

**Files:**
- Create: `blacktable/supabase/migrations/0007_realtime.sql`
- Test: `blacktable/supabase/tests/0007_realtime_test.sql`

**Interfaces:**
- Produces: `supabase_realtime` publication 에 `rooms, seats, piles, cards` 추가. (클라이언트는 `cards` 변경 이벤트의 payload 는 무시하고 "해당 room 무더기 리페치" 트리거로만 사용.)

- [ ] **Step 1: 테스트 작성** — `blacktable/supabase/tests/0007_realtime_test.sql`

```sql
begin;
select plan(1);
select is(
  (select count(*)::int from pg_publication_tables
   where pubname='supabase_realtime' and tablename in ('rooms','seats','piles','cards')),
  4, 'four tables in realtime publication');
select * from finish();
rollback;
```

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 마이그레이션** — `blacktable/supabase/migrations/0007_realtime.sql`

```sql
alter publication supabase_realtime add table rooms, seats, piles, cards;
```

- [ ] **Step 4: 통과 + 커밋**

```bash
supabase db reset && supabase test db
git add blacktable/supabase
git commit -m "feat(blacktable): add core tables to realtime publication"
```

---

## Task 8: Flutter 스캐폴드 + Supabase 초기화 + 라우팅

**Files:**
- Create: `blacktable/lib/main.dart`, `blacktable/lib/env.dart`
- Create: `blacktable/pubspec.yaml` (via `flutter create`)
- Test: `blacktable/test/bootstrap_test.dart`

**Interfaces:**
- Produces: `main()` — `Supabase.initialize` 후 익명 세션 없으면 `signInAnonymously()`. 라우트: `/` (landing), `/create`, `/room/:code` (hand), `/table/:code` (table), `/profile`.
- Consumes: `Env.supabaseUrl`, `Env.supabaseAnonKey`.

- [ ] **Step 1: Flutter 프로젝트 생성**

```bash
cd blacktable
flutter create --platforms=web --project-name blacktable .
flutter pub add supabase_flutter provider go_router
```

- [ ] **Step 2: 실패하는 테스트 작성** — `blacktable/test/bootstrap_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:blacktable/env.dart';

void main() {
  test('Env has compile-time defines with sane defaults for local', () {
    expect(Env.supabaseUrl, isNotEmpty);
    expect(Env.supabaseAnonKey, isNotEmpty);
  });
}
```

- [ ] **Step 3: 실패 확인** — `flutter test test/bootstrap_test.dart` → FAIL (env.dart 없음).

- [ ] **Step 4: `lib/env.dart` 작성**

```dart
class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL', defaultValue: 'http://127.0.0.1:54321');
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY', defaultValue: 'REPLACE_WITH_LOCAL_ANON_KEY');
}
```

(로컬 anon key 는 `supabase status` 출력에서 복사해 defaultValue 에 채운다.)

- [ ] **Step 5: `lib/main.dart` 작성**

```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'env.dart';
import 'screens/landing_screen.dart';
import 'screens/create_room_screen.dart';
import 'screens/hand_screen.dart';
import 'screens/table_screen.dart';
import 'screens/profile_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: Env.supabaseUrl, anonKey: Env.supabaseAnonKey);
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession == null) {
    await auth.signInAnonymously();
  }
  runApp(const BlacktableApp());
}

final _router = GoRouter(routes: [
  GoRoute(path: '/', builder: (_, __) => const LandingScreen()),
  GoRoute(path: '/create', builder: (_, __) => const CreateRoomScreen()),
  GoRoute(path: '/room/:code', builder: (_, s) => HandScreen(code: s.pathParameters['code']!)),
  GoRoute(path: '/table/:code', builder: (_, s) => TableScreen(code: s.pathParameters['code']!)),
  GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
]);

class BlacktableApp extends StatelessWidget {
  const BlacktableApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'blacktable', routerConfig: _router,
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
  );
}
```

- [ ] **Step 6: 화면 파일 5개를 최소 스텁으로 생성** (각각 `Scaffold(body: Center(child: Text('<name>')))`, 생성자 파라미터만 맞춤). `flutter analyze` 통과시키는 게 목적.

- [ ] **Step 7: 테스트 통과 + 빌드 확인**

```bash
flutter test test/bootstrap_test.dart
flutter build web --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_ANON_KEY=$(supabase status -o json | jq -r .ANON_KEY)
```
Expected: 테스트 PASS, 빌드 성공.

- [ ] **Step 8: 커밋**

```bash
git add blacktable
git commit -m "feat(blacktable): flutter web scaffold, supabase init, routing"
```

---

## Task 9: 모델 + 프리셋 상수

**Files:**
- Create: `blacktable/lib/models.dart`, `blacktable/lib/presets.dart`
- Test: `blacktable/test/models_test.dart`, `blacktable/test/presets_test.dart`

**Interfaces:**
- Produces:
  - `class CardView { final String id, pileId; final bool faceUp; final int sortOrder; final String? cardCode; CardView.fromMap(Map) }`
  - `class PileView { final String pileId, roomId, kind; final String? ownerSeatId, label; final double? x, y; final int? z; final bool spread, visible; final int cardCount; ...fromMap }`
  - `class Seat { final String id, roomId, userId, nickname; final int seatIndex, chips; final bool isGuest, connected; ...fromMap }`
  - `class Room { final String id, code, hostId, presetKey, status; final String? currencyLabel; final int? startingChips; ...fromMap }`
  - `class RoomState { final Room room; final List<Seat> seats; final List<PileView> piles; final List<CardView> cards; }`
  - `presets.dart`: `class Preset { final String key; final int minPlayers, maxPlayers; final List<String> deck; final int defaultDeal; }` + `const kPresets = <String, Preset>{ 'trump': ..., 'hwatu': ..., 'tokens': ... }` + `List<String> buildTrumpDeck()` (52 + JOKER1/JOKER2).

- [ ] **Step 1: 실패하는 테스트 작성** — `blacktable/test/presets_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:blacktable/presets.dart';

void main() {
  test('trump deck is 54 unique cards', () {
    final d = buildTrumpDeck();
    expect(d.length, 54);
    expect(d.toSet().length, 54);
    expect(d.where((c) => c.startsWith('JOKER')).length, 2);
  });
  test('trump preset player range mirrors server (2..10)', () {
    expect(kPresets['trump']!.minPlayers, 2);
    expect(kPresets['trump']!.maxPlayers, 10);
  });
}
```

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: `lib/presets.dart` 구현**

```dart
class Preset {
  final String key;
  final int minPlayers, maxPlayers, defaultDeal;
  final List<String> deck;
  const Preset(this.key, this.minPlayers, this.maxPlayers, this.defaultDeal, this.deck);
}

List<String> buildTrumpDeck() {
  const suits = ['S', 'H', 'D', 'C'];
  const ranks = ['A','2','3','4','5','6','7','8','9','10','J','Q','K'];
  return [for (final s in suits) for (final r in ranks) '$r$s', 'JOKER1', 'JOKER2'];
}

List<String> buildHwatuDeck() =>
    [for (var m = 1; m <= 12; m++) for (var i = 1; i <= 4; i++) 'H${m}_$i'];

final kPresets = <String, Preset>{
  'trump': Preset('trump', 2, 10, 7, buildTrumpDeck()),
  'hwatu': Preset('hwatu', 2, 4, 7, buildHwatuDeck()),
  'tokens': Preset('tokens', 1, 30, 0, const []),
};
```

- [ ] **Step 4: `lib/models.dart` 구현** — 위 Interfaces의 클래스들. 각 `fromMap`은 Supabase가 주는 snake_case 키(`pile_id`, `card_code`, `seat_index`, `owner_seat_id`, `card_count`, `starting_chips` 등)를 읽는다. `RoomState`는 조립만.

- [ ] **Step 5: `models_test.dart` 작성** — `CardView.fromMap({'id':'x','pile_id':'p','face_up':false,'sort_order':0,'card_code':null})` 가 필드에 맞게 파싱되는지 1건.

- [ ] **Step 6: 테스트 통과 + 커밋**

```bash
flutter test
git add blacktable/lib blacktable/test
git commit -m "feat(blacktable): domain models + preset constants"
```

---

## Task 10: RoomRepository (RPC + Realtime + 리페치)

**Files:**
- Create: `blacktable/lib/room_repository.dart`
- Test: `blacktable/test/room_repository_it_test.dart` (통합 — 로컬 Supabase 필요)

**Interfaces:**
- Consumes: `models.dart`, `Supabase.instance.client`.
- Produces:
  - `class RoomRepository`
  - `Future<({String roomId, String code})> createRoom({required String presetKey, required String nickname, String? currencyLabel, int? startingChips})`
  - `Future<String> joinRoom(String code, String nickname)` → roomId
  - `Future<String> joinAsTable(String code)` → roomId
  - `Future<void> deal({required String roomId, required String fromPileId, required Map<String,int> counts})`
  - `Future<void> draw({required String roomId, required String fromPileId})`
  - `Future<void> moveCards(List<String> cardIds, String toPileId, {bool? faceUp})`
  - `Future<void> shufflePile(String pileId)` / `setPileSpread(String pileId, bool spread)` / `setChips(String seatId, int delta)` / `createTablePile(...)` / `transferHost(...)` / `claimHost(...)` / `leaveRoom(String roomId)` / `closeRoom(String roomId)` / `updateProfile(...)`
  - `Stream<RoomState> watch(String roomId)` — 최초 1회 풀 로드(`_loadState`) 후, `rooms/seats/piles/cards` 채널 이벤트마다 `_loadState` 재호출해 emit. (무더기 델타 최적화는 안 함 — 방 하나 상태는 작다. ponytail: 전체 리로드로 충분, 프로파일에서 느리면 pile 단위로.)
  - `Future<RoomState> reload(String roomId)` — 포커스 복귀·재연결용 수동 리로드.

- [ ] **Step 1: 실패하는 통합 테스트 작성** — `blacktable/test/room_repository_it_test.dart`

```dart
@Tags(['integration'])
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:blacktable/env.dart';
import 'package:blacktable/room_repository.dart';

void main() {
  setUpAll(() async {
    await Supabase.initialize(url: Env.supabaseUrl, anonKey: Env.supabaseAnonKey);
    await Supabase.instance.client.auth.signInAnonymously();
  });

  test('create -> join -> watch emits room with 2 seats', () async {
    final repo = RoomRepository();
    final created = await repo.createRoom(presetKey: 'trump', nickname: 'Host');
    // 두 번째 익명 유저로 join
    final c2 = SupabaseClient(Env.supabaseUrl, Env.supabaseAnonKey);
    await c2.auth.signInAnonymously();
    await c2.rpc('join_room', params: {'p_code': created.code, 'p_nickname': 'Bob'});

    final state = await repo.watch(created.roomId).firstWhere((s) => s.seats.length == 2);
    expect(state.room.code, created.code);
    expect(state.piles.where((p) => p.kind == 'deck').length, 1);
  });
}
```

- [ ] **Step 2: 실패 확인**

```bash
supabase start
flutter test --tags integration test/room_repository_it_test.dart
```
Expected: FAIL — `room_repository.dart` 없음.

- [ ] **Step 3: `lib/room_repository.dart` 구현**

```dart
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models.dart';

class RoomRepository {
  final SupabaseClient _c = Supabase.instance.client;

  Future<({String roomId, String code})> createRoom({
    required String presetKey, required String nickname,
    String? currencyLabel, int? startingChips}) async {
    final rows = await _c.rpc('create_room', params: {
      'p_preset_key': presetKey, 'p_nickname': nickname,
      'p_currency_label': currencyLabel, 'p_starting_chips': startingChips,
    }) as List;
    final r = rows.first as Map<String, dynamic>;
    return (roomId: r['room_id'] as String, code: r['code'] as String);
  }

  Future<String> joinRoom(String code, String nickname) async =>
      await _c.rpc('join_room', params: {'p_code': code, 'p_nickname': nickname}) as String;

  Future<String> joinAsTable(String code) async =>
      await _c.rpc('join_as_table', params: {'p_code': code}) as String;

  Future<void> deal({required String roomId, required String fromPileId,
      required Map<String, int> counts}) =>
      _c.rpc('deal', params: {'p_room_id': roomId, 'p_from_pile_id': fromPileId, 'p_counts': counts});

  Future<void> draw({required String roomId, required String fromPileId}) =>
      _c.rpc('draw', params: {'p_room_id': roomId, 'p_from_pile_id': fromPileId});

  Future<void> moveCards(List<String> cardIds, String toPileId, {bool? faceUp}) =>
      _c.rpc('move_cards', params: {
        'p_card_ids': cardIds, 'p_to_pile_id': toPileId, 'p_face_up': faceUp});

  Future<void> shufflePile(String pileId) => _c.rpc('shuffle_pile', params: {'p_pile_id': pileId});
  Future<void> setPileSpread(String pileId, bool spread) =>
      _c.rpc('set_pile_spread', params: {'p_pile_id': pileId, 'p_spread': spread});
  Future<void> setChips(String seatId, int delta) =>
      _c.rpc('set_chips', params: {'p_seat_id': seatId, 'p_delta': delta});
  Future<String> createTablePile(String roomId, double x, double y, {String? label}) async =>
      await _c.rpc('create_table_pile',
          params: {'p_room_id': roomId, 'p_x': x, 'p_y': y, 'p_label': label}) as String;
  Future<void> transferHost(String roomId, String toSeatId) =>
      _c.rpc('transfer_host', params: {'p_room_id': roomId, 'p_to_seat_id': toSeatId});
  Future<void> claimHost(String roomId) => _c.rpc('claim_host', params: {'p_room_id': roomId});
  Future<void> leaveRoom(String roomId) => _c.rpc('leave_room', params: {'p_room_id': roomId});
  Future<void> closeRoom(String roomId) => _c.rpc('close_room', params: {'p_room_id': roomId});
  Future<void> updateProfile({String? displayName, String? cardSkin, String? avatarSkin}) =>
      _c.rpc('update_profile', params: {
        'p_display_name': displayName, 'p_card_skin': cardSkin, 'p_avatar_skin': avatarSkin});

  Future<RoomState> reload(String roomId) => _loadState(roomId);

  Future<RoomState> _loadState(String roomId) async {
    final room = await _c.from('rooms').select().eq('id', roomId).single();
    final seats = await _c.from('seats').select().eq('room_id', roomId).order('seat_index');
    final piles = await _c.from('pile_projection').select().eq('room_id', roomId);
    final cards = await _c.from('cards_view').select().eq('room_id', roomId).order('sort_order');
    return RoomState(
      room: Room.fromMap(room),
      seats: (seats as List).map((e) => Seat.fromMap(e)).toList(),
      piles: (piles as List).map((e) => PileView.fromMap(e)).toList(),
      cards: (cards as List).map((e) => CardView.fromMap(e)).toList(),
    );
  }

  Stream<RoomState> watch(String roomId) {
    final ctrl = StreamController<RoomState>();
    RealtimeChannel? ch;
    Future<void> push() async {
      try { ctrl.add(await _loadState(roomId)); } catch (e, st) { ctrl.addError(e, st); }
    }
    ch = _c.channel('room:$roomId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all, schema: 'public',
        callback: (_) => push())
      ..subscribe((status, _) { if (status == RealtimeSubscribeStatus.subscribed) push(); });
    ctrl.onCancel = () async { await _c.removeChannel(ch!); };
    return ctrl.stream;
  }
}
```

> 참고: `onPostgresChanges` 는 테이블별 필터가 필요하면 `table:` 옵션으로 4번 등록한다. v1은 스키마 전체 구독 후 `room_id` 무관 이벤트도 그냥 리로드로 흡수(방 하나짜리 트래픽이라 허용). 프로파일에서 시끄러우면 `filter: 'room_id=eq.$roomId'` 를 각 테이블에 건다.

- [ ] **Step 4: 통과 확인**

```bash
supabase db reset
flutter test --tags integration test/room_repository_it_test.dart
```
Expected: PASS.

- [ ] **Step 5: 커밋**

```bash
git add blacktable/lib blacktable/test
git commit -m "feat(blacktable): RoomRepository — RPC wrappers + realtime state stream"
```

---

## Task 11: RoomController (상태 보유 + 낙관적 갱신)

**Files:**
- Create: `blacktable/lib/room_controller.dart`
- Test: `blacktable/test/room_controller_test.dart`

**Interfaces:**
- Consumes: `RoomRepository`, `models.dart`.
- Produces:
  - `class RoomController extends ChangeNotifier`
  - 생성자 `RoomController(this._repo, this.roomId, {required this.asTable})`
  - `RoomState? get state`, `bool get connected`, `String? get error`
  - `void start()` — `_repo.watch` 구독, 이벤트마다 `_state` 교체 + `notifyListeners`. 에러 시 `connected=false`.
  - `Future<void> resync()` — `_repo.reload` 호출(포커스 복귀/재연결).
  - `Future<void> playCards(List<String> cardIds, String toPileId)` — 낙관적으로 `_state` 에서 카드 이동 후 `notifyListeners`; `_repo.moveCards` 실패하면 `resync()` 로 롤백.
  - `myUserId` = `Supabase.instance.client.auth.currentUser!.id`
  - `Seat? get mySeat`, `bool get isHost`

- [ ] **Step 1: 실패하는 테스트 작성** — fake repo 로 낙관적 롤백 검증.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:blacktable/room_controller.dart';
import 'package:blacktable/models.dart';

class _FakeRepo implements RoomRepositoryLike {
  RoomState next;
  bool failMove = false;
  _FakeRepo(this.next);
  @override Stream<RoomState> watch(String id) => Stream.value(next);
  @override Future<RoomState> reload(String id) async => next;
  @override Future<void> moveCards(List<String> ids, String to, {bool? faceUp}) async {
    if (failMove) throw Exception('conflict');
  }
  // ...나머지는 noSuchMethod 로 위임
  @override dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('failed move triggers resync (rollback)', () async {
    final base = /* 카드 1장이 hand 에 있는 RoomState 구성 */ makeState();
    final repo = _FakeRepo(base)..failMove = true;
    final c = RoomController(repo, base.room.id, asTable: false)..start();
    await Future.delayed(Duration.zero);
    await c.playCards(['card-1'], 'discard-pile');
    // 실패 후 resync 로 base 상태 복원
    expect(c.state!.cards.single.pileId, 'hand-pile');
  });
}
```

- [ ] **Step 2: 실패 확인** — FAIL (`RoomRepositoryLike` 인터페이스, `RoomController` 없음).

- [ ] **Step 3: 구현** — `RoomRepository` 에 `abstract interface class RoomRepositoryLike` 를 추출(또는 `RoomRepository` 가 implements)하고 `RoomController` 작성. 낙관적 갱신은 `_state` 의 `cards` 리스트에서 해당 id 들의 `pileId` 를 즉시 바꾸고, `moveCards` 예외 시 `await resync()`.

- [ ] **Step 4: 통과 + 커밋**

```bash
flutter test test/room_controller_test.dart
git add blacktable/lib blacktable/test
git commit -m "feat(blacktable): RoomController with optimistic move + rollback"
```

---

## Task 12: Landing + Create-room + Join 흐름

**Files:**
- Modify: `blacktable/lib/screens/landing_screen.dart`, `create_room_screen.dart`
- Create: `blacktable/lib/auth_service.dart`
- Test: `blacktable/test/landing_flow_test.dart`

**Interfaces:**
- Consumes: `RoomRepository`, `go_router`.
- Produces:
  - `class AuthService { Future<void> ensureAnon(); Future<void> signInWithGoogle(); Future<void> signOut(); bool get isGuest; }`
  - Landing: `[방 만들기]`→`/create`, `[코드로 참가]` (코드+닉네임 입력 → `joinRoom` → `/room/:code`), `[TV로 보기]` (코드 입력 → `joinAsTable` → `/table/:code`), `[구글로 로그인]`.
  - Create: 프리셋 드롭다운(`kPresets.keys`), 칩 사용 스위치 → 화폐 이름·시작값, `[만들기]` → `createRoom` → 코드/QR 다이얼로그 → `/room/:code`.

- [ ] **Step 1: 위젯 테스트 작성** — `landing_flow_test.dart`: fake repo 주입, "코드로 참가"에 `ABC234`/`Kim` 입력 → `joinRoom('ABC234','Kim')` 호출됐는지 `verify`.

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 화면 구현** — `Provider` 로 `RoomRepository`/`AuthService` 주입. `google_sign_in` 없이 `_c.auth.signInWithOAuth(OAuthProvider.google, redirectTo: <web origin>)` 사용. 게스트 join 전 `AuthService.ensureAnon()` 로 항상 새 익명 세션이 되도록: `signOut()` → `signInAnonymously()` (스펙 §6.2).

- [ ] **Step 4: 통과 + 커밋**

```bash
flutter test test/landing_flow_test.dart
git add blacktable/lib blacktable/test
git commit -m "feat(blacktable): landing, create-room, join flows + auth service"
```

---

## Task 13: 손패 위젯 (부채꼴 + 드래그)

**Files:**
- Create: `blacktable/lib/widgets/card_fan.dart`, `blacktable/lib/widgets/pile_widget.dart`
- Test: `blacktable/test/card_fan_test.dart`

**Interfaces:**
- Produces:
  - `class CardFan extends StatelessWidget` — `final List<CardView> cards; final bool spread; final void Function(CardView) onDragStartHint; final void Function(List<String> ids) onPlay;` 부채꼴 배치는 `Transform.rotate` + 각도 `= (i - n/2) * 6°`. 각 카드는 `Draggable<List<String>>(data: [card.id])`.
  - `class PileWidget extends StatelessWidget` — `final PileView pile; final List<CardView> cards; final bool amHost; final void Function(List<String> ids) onDropCards; final VoidCallback? onToggleSpread;` `DragTarget<List<String>>` 로 드롭 수신. `pile.visible==false` 면 카드 뒷면 겹침 + `Text('${pile.cardCount}')` 없이 "덮인 스택" 아이콘; 소유자 화면에서만 카운트/펼침.
  - 카드 앞면 렌더는 `card.cardCode`(null이면 뒷면 에셋). 스킨은 Task 15에서 주입.

- [ ] **Step 1: 위젯 테스트 작성** — 카드 3장 `CardFan`, 첫 카드 위젯을 `Draggable` 로 찾고, `LongPressDraggable` 제스처 후 `onPlay` 가 `['id-0']` 로 불리는지. (드롭은 `PileWidget` 테스트에서 `DragTarget.onAccept` 직접 호출.)

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 구현.**

- [ ] **Step 4: 통과 + 커밋**

```bash
flutter test test/card_fan_test.dart
git add blacktable/lib blacktable/test
git commit -m "feat(blacktable): card fan + pile widgets with drag/drop"
```

---

## Task 14: 핸드 뷰 화면 조립

**Files:**
- Modify: `blacktable/lib/screens/hand_screen.dart`
- Create: `blacktable/lib/widgets/reconnecting_overlay.dart`
- Test: `blacktable/test/hand_screen_test.dart`

**Interfaces:**
- Consumes: `RoomController`, `CardFan`, `PileWidget`, `ReconnectingOverlay`.
- Produces: `HandScreen({required String code})`. `initState` 에서 `joinRoom` 이 이미 됐다고 가정(landing 에서 옴) → `RoomController(repo, roomId, asTable:false)..start()`. `AnimatedBuilder(animation: controller)` 로 리빌드.
  - 레이아웃: 상단 = 테이블 축소도(공용 무더기 `deck/discard/table_free/named` + 좌석 칩·뒷면 수), 하단 = 내 `CardFan` + 펼침 토글 + 내 칩.
  - 방장이면 AppBar 메뉴: `딜(기본 분배 장수)`, `방장 넘기기(좌석 선택)`, `방 닫기`.
  - `WidgetsBindingObserver.didChangeAppLifecycleState` resume 시 `controller.resync()`. 웹 포커스: `html`/`web` 없이 `AppLifecycleState` 로 충분(Flutter web 지원).
  - `controller.connected == false` 면 `ReconnectingOverlay`.
  - 화면 dispose 시 `repo.leaveRoom(roomId)` (게스트면 좌석 해제, 로그인이면 connected=false).

- [ ] **Step 1: 위젯 테스트 작성** — fake controller 로 `RoomState`(내 손패 2장, deck 5장) 주입 → `CardFan` 에 2장, deck `PileWidget` 에 카운트 5, "딜" 메뉴는 내가 host 일 때만 보임.

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 구현.**

- [ ] **Step 4: 통과 + 커밋**

```bash
flutter test test/hand_screen_test.dart
git add blacktable/lib blacktable/test
git commit -m "feat(blacktable): hand screen assembly + reconnecting overlay"
```

---

## Task 15: 테이블 뷰 화면

**Files:**
- Modify: `blacktable/lib/screens/table_screen.dart`
- Test: `blacktable/test/table_screen_test.dart`

**Interfaces:**
- Consumes: `RoomController(asTable: true)`.
- Produces: `TableScreen({required String code})`. `initState` → `repo.joinAsTable(code)` → `RoomController(..., asTable:true)..start()`.
  - 큰 화면 레이아웃: 중앙에 `deck`/`discard`, 주변에 좌석 카드(닉네임 + 칩 + 뒷면 장수, `connected==false` 면 흐리게 + "연결 끊김" 배지). `table_free`/`named` 무더기는 좌표대로 배치.
  - 조작 없음. 앞면 카드(`card.cardCode != null`)만 실제로 보임.
  - lifecycle resume 시 `resync()`.

- [ ] **Step 1: 위젯 테스트 작성** — 좌석 2개(1명 `connected:false`) 주입 → "연결 끊김" 텍스트 1개, 앞면 카드 1장은 코드 표시·뒷면 카드는 미표시.

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 구현.**

- [ ] **Step 4: 통과 + 커밋**

```bash
flutter test test/table_screen_test.dart
git add blacktable/lib blacktable/test
git commit -m "feat(blacktable): table (TV) view"
```

---

## Task 16: 프로필 + 스킨 + 스킨 주입

**Files:**
- Modify: `blacktable/lib/screens/profile_screen.dart`, `lib/widgets/card_fan.dart` (스킨 파라미터)
- Create: `blacktable/lib/skins.dart`, 에셋 `blacktable/assets/skins/...`
- Test: `blacktable/test/profile_test.dart`

**Interfaces:**
- Produces:
  - `lib/skins.dart`: `const kCardSkins = ['classic', 'dark', 'pastel']; const kAvatarSkins = ['default', 'fox', 'robot']; String cardBackAsset(String skin); String cardFaceAsset(String skin, String code);` (v1은 색상 테마 3종으로 충분 — 실제 이미지 대신 `CustomPaint`/색상 매핑도 허용, ponytail).
  - `ProfileScreen`: 닉네임 필드 + 카드 스킨 라디오 + 아바타 스킨 라디오 → `repo.updateProfile(...)`. 게스트면 "로그인하면 저장됩니다" 안내 + 저장 비활성.
  - `CardFan`/`PileWidget` 에 `String cardSkin` 파라미터 추가, `HandScreen` 이 현재 프로필에서 읽어 전달(프로필 로드는 `_c.from('profiles').select().eq('id', uid).maybeSingle()`).

- [ ] **Step 1: 위젯 테스트 작성** — 로그인(비게스트) 상태 stub 에서 스킨 `dark` 선택 + 저장 → `updateProfile(cardSkin: 'dark')` 호출. 게스트 상태에서 저장 버튼 `disabled`.

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 구현.**

- [ ] **Step 4: 통과 + 커밋**

```bash
flutter test test/profile_test.dart
git add blacktable
git commit -m "feat(blacktable): profile screen + card/avatar skins"
```

---

## Task 17: PWA 매니페스트 + 수동 멀티기기 스모크 문서

**Files:**
- Modify: `blacktable/web/manifest.json`, `blacktable/web/index.html`
- Create: `blacktable/SMOKE.md`
- Test: 없음(문서 + 정적 파일). `flutter build web` 성공이 게이트.

**Interfaces:**
- Produces: 설치 가능한 PWA(name/short_name/icons/display=standalone/theme_color). `SMOKE.md` 에 아래 수동 절차.

- [ ] **Step 1: `web/manifest.json` 갱신** — `name: "blacktable"`, `short_name: "blacktable"`, `display: "standalone"`, `start_url: "/"`, `theme_color: "#00695c"`, 아이콘 192/512.

- [ ] **Step 2: `SMOKE.md` 작성**

```markdown
# blacktable v1 수동 스모크

준비: `supabase start`; `flutter run -d chrome --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`
기기: 노트북 브라우저(테이블 뷰) + 폰 2대(핸드 뷰). 같은 LAN, URL 은 노트북 IP.

## 원카드 한 판
1. 폰A: 방 만들기 → trump, 칩 미사용 → 코드 C 확인.
2. 노트북: [TV로 보기] → C → 테이블 뷰에 deck/discard 보임.
3. 폰B: [코드로 참가] → C, 닉네임 "B".
4. 폰A(방장): 딜 7장 → 두 손패 각 7장, deck 40장. 테이블 뷰에 뒷면 수 갱신.
5. 폰A: 카드 1장 discard 로 드래그(앞면) → 폰B·테이블 뷰에 즉시 반영.
6. 폰B: 잘못 낸 척 → 폰A 가 방금 카드 회수 시도 → 본인 것만 가능(성공). 폰B 가 폰A 카드 회수 시도 → 실패 토스트.
7. 폰A: 손패 펼침 토글 → 테이블 뷰에서 폰A 장수 노출/숨김 전환 확인.

## 재접속
8. 폰B(게스트) 비행기모드 5초 → 해제 → 방 자동 복귀 안 됨, 다시 코드 입력 → **새 좌석**(칩·손패 초기화) 확인.
9. 폰A 를 구글 로그인 후 같은 시나리오 → 비행기모드 해제 시 **좌석·손패 유지** 확인.

## 방장 위임/청소
10. 폰A: 방장 넘기기 → 폰B. 폰B AppBar 에 방장 메뉴 생김.
11. 폰A: 방 닫기 → 폰B·테이블 뷰 "방 종료" 화면.
```

- [ ] **Step 3: 빌드 확인 + 커밋**

```bash
flutter build web --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_ANON_KEY=<local>
git add blacktable
git commit -m "chore(blacktable): PWA manifest + manual smoke checklist"
```

---

## Self-Review

**1. Spec coverage**

| 스펙 항목 | Task |
|---|---|
| §3 아키텍처(Supabase, RPC 관문, 뷰 마스킹) | 1–7 |
| §4 데이터 모델(테이블 6종) | 1 |
| §4.1 숨김 정보(cards_view / pile_projection / spread) | 2, 5(`set_pile_spread`), 13 |
| §4.2 프리셋 + 인원 범위(서버 `preset_range` + 클라 미러) | 1, 5(`deal` 검증), 9 |
| §5 RPC 전량 | 4, 5, 6 |
| §5.1 move_cards 동시성(조건부 UPDATE, conflict) | 5 |
| §6.1 재접속(로그인) | 11(resync), 14/15(lifecycle) |
| §6.2 게스트 이탈 즉시 해제 + named 무더기 | 4(`leave_room`), 12(ensureAnon) |
| §6.3 leave_room 표 | 4 |
| §6.4 방 생명주기 + pg_cron sweep | 4(`close_room`), 6(`sweep_abandoned_rooms`) |
| §6.5 덱 소진 | 5(`draw`/`deal` 예외), SMOKE |
| §6.6 잘못된 입력 | 4·5 각 예외 + 위젯 토스트 |
| §7 화면(랜딩/생성/핸드/테이블/프로필) | 12, 14, 15, 16 |
| §8 테스트(RPC 7 + 클라 해피패스 + 수동) | 2–7(pgTAP), 10(IT), 17(SMOKE) |
| 화폐 방 한정·휘발 | 4(seat.chips, close 시 CASCADE), 모델에 영구 저장 없음 |

갭 없음.

**2. Placeholder scan** — 모든 코드 Step 에 실제 SQL/Dart 포함. Task 11·13·14·15·16 의 Step 3 는 "구현"으로 요약했으나 각 Interfaces 블록에 시그니처·레이아웃 규칙·에셋 경로를 명시했고 Step 1 에 검증 테스트가 실코드로 있음 — 실행자가 채울 여지가 결정적이지 않음. 위젯 픽셀 레이아웃까지 못 박지 않은 것은 의도(디자인 자유).

**3. Type consistency**

- RPC 파라미터 이름(`p_room_id`, `p_from_pile_id`, `p_card_ids`, `p_to_pile_id`, `p_counts`, `p_seat_id`, `p_delta`, `p_code`, `p_nickname`)이 마이그레이션(Task 4–6)과 `RoomRepository`(Task 10) 사이에서 일치.
- `cards_view` 컬럼(`card_code`, `pile_id`, `face_up`, `sort_order`) ↔ `CardView.fromMap`(Task 9) 일치.
- `pile_projection` 컬럼(`pile_id`, `card_count`, `visible`, `spread`, `owner_seat_id`) ↔ `PileView.fromMap`(Task 9) 일치.
- `RoomRepository.watch/reload` ↔ `RoomController`(Task 11)에서 사용하는 이름 일치. `RoomRepositoryLike` 인터페이스는 Task 11 에서 도입하고 Task 10 의 `RoomRepository` 가 `implements` 하도록 Step 3 에 명시.
- `createRoom` 반환 `({String roomId, String code})` ↔ Task 12 create 화면 사용 일치.

불일치 없음.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-08-31-blacktable-v1-table-core.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — 태스크마다 새 서브에이전트, 태스크 사이 리뷰, 빠른 반복.

**2. Inline Execution** — 이 세션에서 executing-plans 로 체크포인트 두고 배치 실행.

**Which approach?**
