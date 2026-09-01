# 반복거래 자동등록 설계

> 상위 스펙: `docs/superpowers/specs/2026-08-25-ppyu-gagyebu-design.md` 의 "카테고리 분류, 반복거래 자동등록" 항목을 구현한다.

## 1. 개요

가구 구성원이 정기적으로 반복되는 지출/수입(월세, 구독료, 급여 등)을 템플릿으로 등록해두면, 앱을 열 때마다 자동으로 실제 거래로 등록해준다. 서버 인프라(Edge Function/cron) 없이 앱 접속 시점 체크만으로 동작한다.

## 2. 데이터 모델

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
  interval_rule text not null, -- 'DAILY' / 'WEEKLY:MO,WE,FR' / 'MONTHLY' / 'YEARLY' (캘린더와 동일 형식)
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
```

- 권한: 가구 구성원 누구나 템플릿 조회/수정/삭제 가능 (기존 `transactions`/`calendar_events`와 동일 철학).
- `insert` 정책은 처음부터 `created_by`가 같은 가구 소속인지 검증한다 — 캘린더 phase 최종 리뷰에서 이 검증 누락이 지적된 뒤 새 마이그레이션으로 고친 전례가 있어, 이번엔 스키마 생성 시점부터 반영한다.
- `interval_rule`은 캘린더의 `recurrence_rule`과 완전히 같은 형식(`DAILY`/`WEEKLY:요일코드`/`MONTHLY`/`YEARLY`)을 재사용한다. 다만 이 테이블에서는 `null`을 허용하지 않는다(반복 없는 "1회성 반복거래"는 의미가 없으므로 `not null`).

**`transactions.source`에 새 값 추가:**

```sql
alter table transactions drop constraint <실제 제약 이름 확인 후 지정>;
alter table transactions add constraint transactions_source_check
  check (source in ('manual', 'notification_auto', 'recurring_auto'));
```
(제약 이름은 `0004_transaction_source_merchant.sql`에서 컬럼 레벨 `check`로 추가돼 Postgres가 자동 생성한 이름이므로, 구현 시 실제 스키마를 조회해 정확한 이름을 확인한다.)

## 3. 소급 생성 메커니즘

**트리거 시점:** 홈 화면 진입 시(`_loadHousehold()` 성공 직후) 한 번 체크. 서버 스케줄러 없음 — 스펙에서 명확히 확정.

**처리 흐름:**
1. 가구의 `recurring_transactions` 중 `next_run_at <= now()`인 템플릿을 전부 조회.
2. 각 템플릿에 대해, `next_run_at`부터 시작해 `interval_rule`을 반복 적용하며 **지금(now) 이전**인 발생 날짜를 순서대로 계산.
3. 계산된 발생 날짜마다 `transactions`에 `source='recurring_auto'`인 거래를 하나씩 생성 (계좌/카테고리/금액/종류/메모는 템플릿 그대로 복사, `occurred_at`은 해당 발생 날짜, `member_id`는 템플릿의 `created_by`).
4. 생성이 끝나면 `next_run_at`을 "마지막으로 생성한 발생 다음 차례" 날짜로 갱신.
5. **소급 상한: 템플릿 하나당 한 번의 체크에서 최대 60건까지만 생성.** 상한에 걸리면 그 시점까지만 생성하고 `next_run_at`을 마지막 생성 발생의 다음 차례로 맞춰서, 다음 앱 실행 때 나머지를 이어서 처리한다. 버그나 오래 방치된 템플릿이 무한/과도한 거래를 한 번에 쏟아내는 것을 막는 안전장치.
6. 실패(네트워크 오류 등)해도 홈 화면 진입 자체를 막지 않는다 — 조용히 넘어가고 다음 진입 때 다시 시도.

**발생 계산 로직:** 캘린더의 `expandOccurrences`와 규칙 형식은 같지만 목적이 다르다(화면 표시용 발생 목록 vs. 실제로 DB에 써야 할 개수). 별도의 작은 순수 함수로 분리해서, "다음 발생 날짜 1개 계산" 또는 "N개 발생 날짜 리스트 계산" 형태로 구현한다 — 캘린더 함수를 억지로 재사용하지 않는다.

## 4. 화면/UI

**반복거래 관리 화면 (`lib/features/ledger/recurring_transaction_screen.dart`, 신규):**
- 목록 + 추가/수정/삭제 (카테고리/태그 관리 화면과 동일 패턴)
- 각 항목: 계좌, 카테고리, 금액, 종류(수입/지출), 주기, 다음 실행일 표시
- 작성/수정 폼: 계좌·카테고리 드롭다운(기존 거래 작성 화면 패턴 재사용), 금액, 종류, 주기 규칙(캘린더 작성 화면의 빈도 드롭다운 + 요일 칩 UI 재사용), 시작일(=최초 `next_run_at`)
- 삭제 시 확인 다이얼로그: "템플릿만 삭제되고 이미 생성된 과거 거래는 그대로 남는다"는 문구 명시

**홈 화면:**
- "반복거래 관리" 메뉴 항목 추가
- `_loadHousehold()` 성공 직후 소급 생성 체크 실행. 새로 생긴 거래가 있으면 짧은 안내(예: "3건의 반복거래가 등록됐어요" 스낵바), 없으면 아무 표시도 하지 않음.

**거래 목록:**
- `source == 'recurring_auto'`인 거래에 `Icons.repeat` 아이콘 표시 (알림 자동인식의 `Icons.notifications_active`와 구분되는 별도 아이콘).

**CSV 내보내기:** 별도 변경 없음 — 이미 있는 "구분"(수입/지출) 컬럼만 사용, `source` 구분은 화면 아이콘에만 반영.

## 5. 에러/엣지 케이스

- 소급 생성 상한(60건)에 걸린 템플릿은 다음 실행에서 이어서 처리 (섹션 3-5 참조).
- 템플릿의 계좌/카테고리가 나중에 삭제되면? — `accounts`/`categories`는 `on delete restrict`로 이미 보호되어 있어 사용 중인 계좌/카테고리는 삭제 자체가 막힌다(기존 정책과 동일). 별도 처리 불필요.
- 소급 생성 도중 일부만 성공하고 중간에 실패하면? — 각 거래 생성은 독립적인 insert이므로, 실패 시점까지 생성된 거래는 그대로 유효하고 `next_run_at`은 마지막으로 "성공 확인된" 발생 다음 차례로만 갱신한다(실패한 발생은 다음 체크에서 재시도됨 — 중복 생성 방지를 위해 `next_run_at` 갱신은 반드시 해당 발생의 insert가 성공한 뒤에만 진행).
- 템플릿 삭제 시 이미 생성된 `transactions` 행은 영향받지 않는다(FK 관계 없음 — `recurring_auto`는 `transactions.source`의 값일 뿐, `recurring_transactions`를 참조하는 컬럼이 아님).

## 6. 테스트 계획

- SQL 테스트 (`supabase/tests/0010_recurring_transactions_test.sql`): RLS가 다른 household를 못 보게 막는지, insert 정책이 `created_by`의 가구 소속을 검증하는지(캘린더 phase의 최종 수정과 동일한 검증 패턴)
- Dart 리포지토리 테스트 (실제 `SupabaseClient` + 로컬 `HttpServer` 패턴): `RecurringTransactionRepository`의 list/create/update/delete
- 소급 생성 로직 순수 함수 유닛 테스트: 밀린 횟수만큼 정확히 생성되는지, 60건 상한이 정확히 작동하는지, 반복 없이 이미 지난 발생이 하나도 없는 경우 아무것도 생성하지 않는지, 각 규칙 타입(DAILY/WEEKLY/MONTHLY/YEARLY)별 다음 발생 계산이 정확한지

## 7. 범위 밖 (이번 Phase에서 제외)

- 서버 사이드 스케줄링(Supabase Edge Function + cron) — 앱 접속 시 체크만 지원
- 반복거래 일시정지(pause) — 삭제만 지원, 필요해지면 나중에 추가
- 개별 발생 건너뛰기/예외 처리 — 캘린더와 동일하게 이번 범위에서 제외
