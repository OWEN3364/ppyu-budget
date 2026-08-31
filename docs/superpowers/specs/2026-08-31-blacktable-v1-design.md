# blacktable v1 설계

> 신규 프로젝트. 이 저장소(`ppyu_budget`)와 무관한 별도 제품이며, 구현 시 별도 디렉터리/저장소로 분리한다.
> 이 문서는 **서브프로젝트 1(테이블 코어 + 얇은 계정)** 의 스펙이다. 경제 레이어 확장, 텍스트 채팅, 원격 플레이 모드, 게임 프리셋 추가, 스킨 상점은 각각 별도 서브프로젝트로 분리한다.

## 1. 개요

여러 명이 각자 폰만 들고 모여서 보드게임·카드게임을 하게 해주는 앱. 실물 구성품이나 테이블이 없어도 된다.

- **핸드 뷰** (각자 폰): 내 손패(비공개), 내 칩, 카드 내기/회수 등 조작.
- **테이블 뷰** (TV·태블릿·빔·서브폰): 공용 테이블만 표시. 로그인 불필요, 조작 최소.
- 방장이 게임 프리셋을 고르면 그것은 **판 세팅 프리셋**일 뿐이다. 룰 자동 진행은 하지 않는다 — 잘못 낸 카드 회수, 임의 섞기·재분배가 가능한 실물 테이블 수준의 자유도를 보장한다.

**v1 대표 게임:** 원카드, 도둑잡기(올드메이드). 둘 다 "트럼프 52 + 조커" 프리셋 하나로 커버되고 베팅이 없다.

**명시적 비범위 (v1):**
- 영상통화 — 아예 안 만든다.
- 보이스 채팅 — v1 범위 밖.
- 텍스트 채팅 — v1 범위 밖 (같은 방에 모여 하는 시나리오 우선).
- 게임별 룰 자동화·점수 자동 집계 — 하지 않는다.
- 스킨 상점·결제·인벤토리 — 하지 않는다 (기본 스킨 2~3종만).
- 방 간 화폐 지속·거래·환전 — 하지 않는다 (사행성 회피).
- 네이티브 앱 배포 — v1은 웹(PWA)만. 반응 보고 Flutter 네이티브로 감쌈.

## 2. 화폐·사행성 정책 (설계 제약)

- 화폐(코인/칩/골드/나뭇잎/별가루 등 방장이 이름 지정)는 **방 한정·휘발성**이다.
- 방장이 참가자 인당 시작 화폐를 지정한다. `starting_chips = null`이면 칩 미사용(원카드·도둑잡기 기본).
- 방을 나가거나 방이 닫히면 그 방의 칩은 소멸한다. 방 간 이월·소유·거래·환전 경로를 **어떤 형태로도 만들지 않는다.**
- 화폐를 현금으로 구매하는 경로 없음. 환전 경로 없음.
- 계정에 영구 저장되는 것은 게임 진행 상태가 아니라 **개인 취향**(닉네임, 카드 스킨, 아바타 스킨, 기본 설정)뿐이다.

## 3. 아키텍처

**프론트엔드:** Flutter, v1은 Web 빌드로 배포(PWA — 홈 화면 추가 가능). 나중에 같은 코드베이스로 네이티브 앱화.

**백엔드:** Supabase 단일 스택.
- **Auth** — 구글 소셜 로그인 1종 + 익명 세션(게스트).
- **Postgres** — 방·좌석·무더기·카드·프로필.
- **Realtime** — 방 단위 채널. Postgres 변경 구독 + presence(접속/이탈).
- **RPC** (`security definer` 함수) — 모든 상태 변경의 유일한 관문.
- **RLS + 뷰** — 숨김 정보(손패 내용) 강제.

**데이터 흐름 한 줄:**
클라이언트는 렌더만 → 사용자 동작 → RPC 호출 → Postgres 갱신 → Realtime이 그 방 전원에게 "변경됨" 통지 → 각 클라이언트가 **바뀐 무더기만** `cards_view`에서 다시 읽어 그림(델타 아님, 무더기 단위 리페치).

**권위 모델:** 상태의 진실은 Postgres에 있다. 클라이언트 낙관적 UI는 화면 반응성만을 위한 것이며 RPC 결과로 정정된다. 자유도 우선 설계라 무거운 권위 게임 루프는 없고, RPC의 얇은 검증(누가 무엇을 만질 수 있는가)만으로 충분하다.

## 4. 데이터 모델 (Postgres)

```sql
-- 프로필: auth.users 1:1. 게스트(익명)도 행이 생기지만 휘발로 취급.
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  card_skin   text not null default 'classic',   -- 기본 스킨 2~3종. enum 대신 문자열
  avatar_skin text not null default 'default',
  created_at timestamptz not null default now()
);
-- 스킨 인벤토리 테이블 없음. 상점이 생기면 그때 추가.

create table rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                      -- 6자 대문자+숫자 (헷갈리는 문자 제외)
  host_id uuid not null references auth.users(id),
  preset_key text not null,                       -- 'trump' | 'hwatu' | 'tokens'
  status text not null default 'lobby',           -- 'lobby' | 'playing' | 'closed'
  currency_label text,                            -- 방장이 지정한 화폐 이름. null이면 칩 미사용
  starting_chips int,                             -- null이면 칩 미사용
  created_at timestamptz not null default now()
);

-- 테이블 뷰(TV)도 익명 세션으로 접속하며, 좌석이 아니라 이 행을 갖는다.
create table table_viewers (
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  last_seen timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table seats (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  is_guest boolean not null default true,         -- 익명 세션이면 true
  seat_index int not null,                        -- 0..29 (방 정원 30석)
  nickname text not null,                         -- 스냅샷(게스트 이름 표시용)
  chips int not null default 0,
  connected boolean not null default true,
  last_seen timestamptz not null default now(),
  unique(room_id, user_id),
  unique(room_id, seat_index)
);

create table piles (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  kind text not null,                             -- 'deck'|'discard'|'hand'|'table_free'|'named'
  owner_seat_id uuid references seats(id) on delete set null,  -- kind='hand'일 때만
  label text,
  x real, y real, z int,                          -- 테이블 위 위치(자유 배치)
  spread boolean not null default false           -- false=겹침(장수·배열 비공개), true=펼침
);

create table cards (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references rooms(id) on delete cascade,
  pile_id uuid not null references piles(id) on delete cascade,
  card_code text not null,                        -- 'AS','KH','JOKER1' / 화투는 별도 코드공간
  face_up boolean not null default false,
  sort_order int not null                         -- 무더기 내 순서
);
```

### 4.1 숨김 정보 처리

- `cards` 원본 테이블: 클라이언트 직접 SELECT 차단. `service_role` 및 RPC(`security definer`)만 접근.
- 클라이언트는 `cards_view` 를 읽는다:

```sql
create view cards_view as
select
  c.id, c.room_id, c.pile_id, c.face_up, c.sort_order,
  case
    when c.face_up then c.card_code
    when p.kind = 'hand' and s.user_id = auth.uid() then c.card_code
    else null                                     -- 뒷면: 내용 마스킹
  end as card_code
from cards c
join piles p on p.id = c.pile_id
left join seats s on s.id = p.owner_seat_id
where exists (                                     -- 그 방의 참가자
  select 1 from seats me where me.room_id = c.room_id and me.user_id = auth.uid()
) or exists (                                       -- 또는 그 방의 테이블 뷰
  select 1 from table_viewers tv where tv.room_id = c.room_id and tv.user_id = auth.uid()
);
```

- **장수 비공개:** `piles.spread = false` 인 무더기는, 비소유자에게 개별 카드 행을 노출하지 않고 "겹친 스택 1개"로만 내려준다. 소유자 본인은 항상 전체를 본다. 정확히 세려면 `set_pile_spread(pile_id, true)` 로 펼쳐야 한다(실물 그대로).
  - 구현: `cards_view` 위에 `pile_projection` 뷰를 하나 더 둔다 — `spread=false` 이고 요청자가 비소유자면 `card_count`만 노출하고 카드 배열은 빈 값. `spread=true` 또는 소유자면 카드 배열 전체.
- 손패 무더기는 생성 시 `spread=false`(자연스러운 비공개). 사용자가 정리/공개할 때 펼친다.
- 테이블 위 자유 더미도 같은 토글을 쓴다(누가 몇 장 가져갔는지 안 보이게 덮어두기 등).

### 4.2 프리셋

덱 구성·기본 분배 장수·게임 인원 범위는 정적 데이터다. Flutter 클라이언트 상수로 두고 DB에는 `preset_key`만 저장한다.

| preset_key | 덱 구성 | 게임 인원 | 기본 분배 | 자동 생성 무더기 |
|---|---|---|---|---|
| `trump` | 52장 + 조커 2장 | 2~10 | 원카드 7장 / 도둑잡기 균등 / 방장 수정 가능 | `deck`(중앙), `discard` |
| `hwatu` | 화투 48장 | 2~4 | 방장 지정 | `deck`, `discard` |
| `tokens` | 카드 없음 | 1~30 | — | 주사위, 범용 토큰 무더기 |

- **방 정원은 30명 고정.** 프리셋의 "게임 인원"은 한 판에 실제로 참여(=`deal` 대상)할 수 있는 인원 범위다.
- `deal` 시 카드를 받는 좌석 수가 프리셋 범위를 벗어나면 거부. 범위를 넘는 나머지 인원은 관전자로 방에 머문다(좌석은 있으나 그 판에는 미참여).
- 인원 범위는 프리셋 상수일 뿐이므로 게임 추가 시 값만 정의하면 된다.

## 5. RPC 함수 (v1 전체)

모두 `security definer`. 호출자는 `auth.uid()`로 식별.

| 함수 | 권한 | 동작 |
|---|---|---|
| `create_room(preset_key, currency_label?, starting_chips?)` | 로그인/게스트 | 방 생성 + 6자 코드 발급 + 방장 좌석 생성. 반환: room, code, table URL |
| `join_room(code, nickname)` | 로그인/게스트 | `auth.uid()`의 좌석을 생성(방 정원 30석). **로그인 사용자만** 기존 좌석 재바인딩(재접속). 게스트는 항상 새 좌석 |
| `join_as_table(code)` | 익명 | `table_viewers` 행 생성(좌석 아님). 반환: 공용 방 상태. 좌석 수에 포함 안 됨 |
| `leave_room(room_id)` | 본인 | 좌석 처리(§6.3 참조) |
| `close_room(room_id)` | 방장 | `rooms` 행 삭제 → CASCADE로 seats/piles/cards 정리 |
| `transfer_host(room_id, to_seat_id)` | 방장 | `rooms.host_id` 교체 |
| `claim_host(room_id)` | 참가자 | 현재 방장이 `connected=false`로 2분 경과 시에만 성공 |
| `deal(room_id, from_pile_id, counts)` | 방장 | 덱에서 각 손패로 카드 이동. `counts`는 좌석별 장수(맵). 대상 좌석 수가 프리셋 인원 범위 밖이면 거부 |
| `draw(room_id, from_pile_id)` | 참가자 | 지정 무더기 맨 위(최대 sort_order) 1장 → 내 손패 |
| `move_cards(card_ids, to_pile_id, at_sort_order?, face_up?)` | 참가자 | 카드들을 다른 무더기로. **출발 무더기가 내 손패 또는 테이블(자유더미/discard) 인 카드만.** 남의 손패·엎힌 `deck`은 불가 |
| `shuffle_pile(pile_id)` | 방장(모든 무더기) / 참가자(자기 손패·테이블 자유더미) | 서버가 `sort_order` 무작위 재배정 |
| `set_pile_spread(pile_id, spread)` | 소유자(손패) / 방장·조작자(테이블 무더기) | 겹침/펼침 토글 |
| `set_chips(seat_id, delta)` | 방장(전원) / 참가자(자기 좌석만) | 칩 증감. 결과가 음수면 거부 |
| `create_table_pile(room_id, x, y, label?)` | 참가자 | 테이블 위 빈 자유 무더기 생성 |
| `update_profile(display_name?, card_skin?, avatar_skin?)` | 로그인 사용자 | 프로필 갱신. 게스트는 무효 |

### 5.1 `move_cards` 동시성

락을 쓰지 않는다. 조건부 UPDATE 하나로 처리:

```sql
update cards set pile_id = $to, sort_order = ..., face_up = coalesce($face_up, face_up)
where id = any($card_ids)
  and pile_id = any($allowed_source_pile_ids);  -- 호출 시점에 계산된, 이 사용자가 만질 수 있는 무더기
-- 영향 행 수 < array_length($card_ids) 이면 → 'conflict' 예외 발생
```

`$allowed_source_pile_ids` = (내 손패) ∪ (그 방의 `discard`·`table_free` 무더기들). 다른 사람이 먼저 카드를 옮겨 `pile_id`가 바뀌었으면 조건에 안 걸려 행 수가 모자라고, RPC는 `conflict`를 던진다. 클라이언트는 낙관적 UI를 되돌리고 해당 무더기를 리페치한다.

## 6. 재접속 · 생명주기 · 에러 처리

### 6.1 연결 끊김 → 복구 (로그인 사용자)

- 끊기면 클라이언트는 마지막 화면을 read-only로 유지하고 "재연결 중"을 표시.
- 복구 시: Realtime 채널 재구독 → 방 전체 상태 1회 풀 리페치 → presence 갱신 → `seats.connected=true`, `last_seen` 갱신.
- 좌석·손패·칩은 `seats(room_id, user_id)` 키로 그대로 복구.
- 떠나 있는 동안 방이 닫혔으면 → "방이 종료되었습니다" 화면.
- **안전망:** 창 포커스 복귀(`visibilitychange`) 시 풀 리페치 1회. 주기 폴링 타이머는 넣지 않는다 — 실측에서 상태 드리프트가 관찰되면 그때 추가한다. (ponytail: on-focus 리페치로 충분, 아니면 20초 타이머)

### 6.2 게스트 이탈 (signup 유인 — 의도된 동작)

- 게스트는 방에 들어올 때마다 **새 익명 신원**을 발급받는다(클라이언트가 `join_room` 전에 `signOut()` → `signInAnonymously()`).
- presence 끊김(짧은 순간 끊김 포함) 또는 `leave_room` → 게스트 좌석 **즉시 해제**. 유예 시간 없음.
- 나간 게스트의 손패 → 테이블 위 `named` 무더기 `"{nickname} (나감)"`, **엎어서**(spread=false, face_up=false) 남긴다. 덱에 자동 흡수하지 않는다(도둑잡기처럼 패가 사라지면 게임이 깨지므로). 방장이 되섞거나 재분배하거나 삭제.
- 게스트 칩은 소멸.
- 재입장 = 완전히 새 좌석 + 새 닉네임 입력.

### 6.3 `leave_room` 처리 요약

| 나가는 사람 | 좌석 | 손패 | 칩 | 방장 권한 |
|---|---|---|---|---|
| 로그인 참가자 | `connected=false` 유지 | 유지 | 유지 | — |
| 게스트 참가자 | 즉시 삭제 | `named` 무더기로 이관(엎음) | 소멸 | — |
| 방장(로그인) | `connected=false` 유지 | 유지 | 유지 | 접속 중 좌석 중 `seat_index` 최소에게 자동 위임. 없으면 방 닫힘 |
| 방장(게스트) | 즉시 삭제 | `named` 무더기로 이관 | 소멸 | 위와 동일 |

### 6.4 방 생명주기

- `close_room`(방장 명시적 종료) → `rooms` 행 삭제 → CASCADE 정리.
- 방장이 안 닫고 사라진 방 → pg_cron 잡 1개가 하루 1회 "접속 중 좌석 0이 6시간 이상 지속"인 방을 삭제.

### 6.5 덱 소진

- 빈 무더기에서 `draw` → 에러. 클라이언트가 "덱이 비었습니다" 토스트.
- 방장이 "버린 패 되섞기" = 기존 RPC 두 번(`move_cards`(discard 전체 → deck) + `shuffle_pile`). 전용 RPC 없음.

### 6.6 기타 입력 오류

- 없는 코드 / 방 정원 초과(30석) / 프리셋 인원 범위 밖 `deal` / `lobby` 아닌데 `deal` / 남의 좌석 `set_chips` → RPC 예외, 클라이언트 토스트.
- Realtime 통지 유실 → 다음 이벤트나 on-focus 리페치까지 잠시 stale. 허용.

### 6.7 치팅 경계 (천장 명시)

RLS + `cards_view`/`pile_projection` 마스킹 + RPC의 출발 무더기 검증이 방어선이다. **친구끼리 한 방에서 하는 테스트 수준**까지만 방어한다. 작정한 공격자(트래픽 분석, 타이밍 공격 등)에 대한 하드닝은 v1 범위 밖이며, 서브프로젝트로 전용 권위 WebSocket 서버(접근 2)로 이전할 때 함께 다룬다.

## 7. 화면 (Flutter)

- **랜딩:** [방 만들기] / [코드로 참가]. 구글 로그인 버튼(선택). 게스트로 계속 가능.
- **방 만들기:** 프리셋 선택 → (선택) 화폐 이름·시작 화폐 입력 → 생성 → 코드·테이블 URL을 크게 표시(QR 포함).
- **핸드 뷰(참가자):**
  - 하단: 내 손패(부채꼴). 길게 눌러 선택, 위로 드래그해 테이블/버림에 내기. 펼침/겹침 토글 버튼.
  - 상단: 테이블 축소도(공용 무더기, 상대별 카드 뒷면 수·칩).
  - 내 칩 표시 + (칩 사용 방이면) 칩 이동 UI.
  - 방장이면: 세팅·`deal`·`transfer_host`·`close_room` 메뉴.
  - 프리셋 인원 범위를 넘어 `deal` 대상에서 빠진 좌석은 "관전 중" 표시(손패 없음, 테이블·칩은 봄).
- **테이블 뷰(TV):** 로그인 없이 코드로 접속. 공용 무더기·좌석별 뒷면 수·칩만 크게. 조작 없음(또는 방장 폰에서 원격 제어만). presence로 "OO 연결 끊김" 배지.
- **프로필(로그인):** 닉네임, 카드 스킨(2~3종), 아바타 스킨(2~3종).

## 8. 테스트 전략

**DB/RPC (보안·상태 핵심 — 필수):** 평이한 SQL 테스트 함수 또는 pgTAP.

1. `move_cards`가 **남의 손패**에서의 이동 시도를 `conflict`/거부로 막는다.
2. `cards_view`가 남의 엎힌 카드의 `card_code`를 `null`로 마스킹한다.
3. `pile_projection`이 `spread=false` 무더기의 장수를 비소유자에게 노출하지 않는다.
4. 동시 `move_cards` 두 건 → 두 번째가 `conflict`.
5. `deal`은 방장만이고 대상 좌석 수가 프리셋 인원 범위(trump 2~10 등) 밖이면 거부. `transfer_host`는 방장만. `claim_host`는 방장 `connected=false` 2분 경과 시에만.
6. `set_chips` 결과가 음수면 거부. 참가자는 자기 좌석만.
7. 게스트 `leave_room` → 좌석 삭제 + 손패가 `named` 무더기로 이관.

**클라이언트:** 통합 테스트 1개 — 로컬 Supabase 상대로 `join → deal → 카드 내기 → 회수` 해피패스.

**수동 스모크:** 폰 2대 + TV 브라우저 1대로 원카드 한 판, 도둑잡기 한 판. 중간에 게스트 1명 강제 종료 후 재입장(새 좌석 확인), 로그인 1명 비행기모드 토글 후 복구(좌석 유지 확인).

**안 함:** 풀 e2e 하니스, 테스트 프레임워크 도입.

## 9. 이후 서브프로젝트 (참고, 이번 범위 아님)

1. **(이 문서)** 테이블 코어 + 얇은 계정 + 트럼프 프리셋.
2. 화폐 레이어 심화(칩 이동 UX, 팟, 방장 프리셋) + 화투 프리셋.
3. 인앱 텍스트 채팅 + 원격 플레이 모드(같은 공간 아님 전제).
4. 게임 추가 파이프라인(프리셋 에디터/SDK), 아동 모드, 보드게임류.
5. 스킨 상점·결제·인벤토리.
6. 네이티브 앱 래핑, 전용 권위 서버로 이전(치팅 하드닝).
