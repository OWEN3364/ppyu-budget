# 통계/리포트 + 소비 절감 추천 + 태그/검색/CSV 내보내기 설계

> 상위 스펙: `docs/superpowers/specs/2026-08-25-ppyu-gagyebu-design.md` 의 "월간/연간 통계 그래프", "규칙 기반 소비 절감 추천", "태그/메모/검색", "CSV/엑셀 내보내기" 항목을 구현한다.

## 1. 개요

Phase 1(인증/가구)·Phase 2(핵심 가계부)·Phase 3(알림 자동인식)에 이어지는 Phase 4. 이번 달 카테고리별 지출을 그래프로 보여주고, 전월 대비 급증한 카테고리를 홈/리포트 화면에 추천으로 노출하며, 거래에 태그를 붙여 검색/필터링하고, 선택한 기간의 거래를 CSV로 내보낼 수 있게 한다.

## 2. 데이터 모델

**신규 테이블 (`0005_stats_tags_nickname.sql`):**

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
```

- `tags`: 카테고리처럼 가구 단위로 미리 정의. `unique (household_id, name)`으로 중복 이름 방지.
- `transaction_tags`: 다대다 연결. 거래 삭제 시 자동 정리(on delete cascade), 태그 삭제 시 연결만 제거되고 거래 자체는 남는다.
- `household_members.nickname`: nullable. 최초엔 비어 있고, 설정 화면에서 입력. 값이 없으면 UI에서 "가족 구성원"으로 표시.

**RLS:** `tags`, `transaction_tags` 둘 다 기존 `is_household_member()` 패턴 그대로 적용. `transaction_tags`는 household_id 컬럼이 없으므로, `exists (select 1 from transactions t where t.id = transaction_id and is_household_member(t.household_id))` 형태로 조인해서 체크한다.

## 3. 백엔드 집계 함수

두 개의 `security definer` Postgres 함수 (기존 프로젝트 컨벤션대로 `set search_path = public, pg_temp` + `revoke execute ... from public, anon`):

```sql
create or replace function get_monthly_category_summary(p_household_id uuid, p_month date)
returns table (category_id uuid, category_name text, type text, total_amount bigint)
language sql security definer set search_path = public, pg_temp stable
as $$
  select c.id, c.name, c.type, coalesce(sum(t.amount), 0)
  from categories c
  left join transactions t
    on t.category_id = c.id
    and t.household_id = p_household_id
    and date_trunc('month', t.occurred_at) = date_trunc('month', p_month)
  where c.household_id = p_household_id
    and is_household_member(p_household_id)
  group by c.id, c.name, c.type
  having coalesce(sum(t.amount), 0) > 0;
$$;
```

```sql
create or replace function get_spending_recommendations(p_household_id uuid, p_month date)
returns table (category_id uuid, category_name text, current_amount bigint, previous_amount bigint, change_ratio numeric)
language sql security definer set search_path = public, pg_temp stable
as $$
  with current_month as (
    select * from get_monthly_category_summary(p_household_id, p_month) where type = 'expense'
  ), previous_month as (
    select * from get_monthly_category_summary(p_household_id, (p_month - interval '1 month')::date) where type = 'expense'
  )
  select cm.category_id, cm.category_name, cm.total_amount, coalesce(pm.total_amount, 0),
    case when coalesce(pm.total_amount, 0) = 0 then null
         else round((cm.total_amount - pm.total_amount)::numeric / pm.total_amount * 100, 1)
    end
  from current_month cm
  left join previous_month pm on pm.category_id = cm.category_id
  where coalesce(pm.total_amount, 0) > 0
    and (cm.total_amount - pm.total_amount)::numeric / pm.total_amount > 0.2
  order by (cm.total_amount - pm.total_amount)::numeric / pm.total_amount desc
  limit 3;
$$;
```

- 전월 지출이 0(또는 데이터 없음)인 카테고리는 추천 대상에서 제외한다 (첫 지출을 "무한대 증가율"로 잘못 추천하는 것 방지).
- 임계치 +20%는 하드코딩 (설정 화면 없음 — 확정).
- `get_spending_recommendations`가 `get_monthly_category_summary`를 재사용해서 두 함수의 "이번 달 카테고리 합계" 로직이 벌어지지 않게 한다.

## 4. 화면/UI

**통계 화면 (`lib/features/stats/stats_screen.dart`, 신규):**
- 월 선택기(◀ 2026년 8월 ▶) + `get_monthly_category_summary` 결과로 카테고리별 지출 원형 그래프(지출)와 막대 그래프(수입 vs 지출) 표시
- 소비 절감 추천 카드: `get_spending_recommendations` 결과를 리스트로("식비 +35% 늘었어요" 형태)
- CSV 내보내기 버튼: 선택된 월의 거래 전체(계좌/카테고리/금액/메모/가맹점/태그/입력자/일시)를 CSV 문자열로 만들어 임시 파일에 쓰고 `share_plus`의 `Share.shareXFiles`로 공유 시트 호출. 서버로 전송하지 않음, 기기 내 생성.

**홈 화면 (`lib/features/household/home_screen.dart` 수정):**
- 이번 달 추천 카드 1개 추가 (통계 화면과 동일한 리포지토리 함수 재사용, 최상위 1건만 요약 표시)
- "통계" 메뉴 항목 추가 → `StatsScreen`으로 이동

**태그 관리 (`lib/features/ledger/tag_repository.dart` + `tag_management_screen.dart`, 신규):**
- `TagRepository`: `list(householdId)`, `create(householdId, name)`, `delete(tagId)` — `CategoryRepository`와 동일한 패턴
- 관리 화면: 카테고리 관리 화면과 동일한 목록+추가+삭제 UI

**거래 작성/수정 화면 (`transaction_form_screen.dart`, `transaction_detail_screen.dart` 수정):**
- 태그 다중 선택 칩 UI 추가 (household의 전체 태그 목록에서 선택/해제)
- 저장 시 `transaction_tags` 테이블에 선택된 태그들 반영 (기존 연결 삭제 후 재삽입 — 단순하고 멱등적인 방식)

**거래 목록 화면 (`transaction_list_screen.dart` 수정):**
- 상단에 텍스트 검색바 추가 — 메모/가맹점 부분일치 검색 (클라이언트 사이드 필터링, 이미 불러온 목록 대상)
- 검색바 아래 태그 필터 칩 (다중 선택 가능, OR 조건 — 선택된 태그 중 하나라도 걸린 거래만 표시)

**닉네임 입력 (신규 다이얼로그, 별도 화면 아님):**
- 현재 앱엔 별도 "설정" 화면이 없음 — 새 화면을 만드는 대신 홈 화면에 "닉네임 설정" 메뉴 항목을 추가하고, 탭하면 텍스트 입력 `AlertDialog`로 처리 (다른 화면과 UI 규모가 안 맞는 별도 화면보다 가벼움)
- `household_members`엔 아직 update RLS 정책이 전혀 없음(RLS는 매칭되는 정책 없으면 기본 거부) — 본인 행만 수정 가능한 정책을 신규 추가해야 함:
  ```sql
  create policy "members can update own nickname" on household_members
    for update using (user_id = auth.uid()) with check (user_id = auth.uid());
  ```
- 거래 목록/통계에서 `member_id` → 닉네임 조인해서 표시, 닉네임 없으면 "가족 구성원"

## 5. 에러/엣지 케이스

- 이번 달 거래가 하나도 없음 → 통계 화면에 그래프 대신 "이번 달 기록된 거래가 없어요" 안내
- 전월 데이터가 없어 증감률 계산 불가 → 해당 카테고리는 추천에서 자동 제외 (함수 자체에서 필터링됨)
- 태그 이름 중복 생성 시도 → `unique` 제약 위반, UI에서 "이미 있는 태그예요" 에러 표시
- 사용 중인 태그를 관리 화면에서 삭제 → `transaction_tags` cascade로 연결만 제거, 해당 거래는 그대로 유지 (태그만 빠짐), 삭제 전 확인 다이얼로그 표시
- CSV 내보내기 시 거래가 0건인 달 → 헤더만 있는 CSV 대신 버튼 비활성화 + 안내 문구
- 닉네임 미입력 상태 → "가족 구성원"으로 표시, 강제 입력 요구하지 않음

## 6. 테스트 계획

- SQL 테스트 (`supabase/tests/0005_stats_tags_nickname_test.sql`, 기존 `begin/rollback + savepoint` 패턴): `get_monthly_category_summary`/`get_spending_recommendations`가 다른 household 데이터를 안 새는지, 전월 0원 카테고리가 추천에서 빠지는지, `transaction_tags`의 RLS가 남의 household 태그 연결을 막는지
- Dart 리포지토리 테스트 (기존 실제 `SupabaseClient` + 로컬 `HttpServer` 패턴 — mocktail 금지 컨벤션 유지): `TagRepository`, 통계 함수 RPC 호출 래퍼
- 위젯 테스트: 태그 필터 칩 다중 선택, 검색바 입력에 따른 목록 필터링

## 7. 범위 밖 (이번 Phase에서 제외)

- 임계치(+20%) 커스터마이징 설정 화면 — 하드코딩 확정
- 연간 통계 요약, 월별 추이(선 그래프) — 이번 Phase는 "월간 카테고리별" 그래프만
- 태그 자유 입력 — 사전 정의 태그만 (카테고리와 동일 모델)
- 고정 광고 배너 — 사용자가 별도로 요청, 위치/크기 미정, 추후 별도 Phase
