# 공유 캘린더 (코어) 설계

> 상위 스펙: `docs/superpowers/specs/2026-08-25-ppyu-gagyebu-design.md` 의 "공유 캘린더" 항목 중 **코어 부분만** 구현한다. Google 캘린더 양방향 동기화는 범위 밖 — 별도 Phase로 분리.

## 1. 개요

가구 구성원끼리 공유하는 일정을 등록·조회한다. 기본 CRUD + 반복 일정(요일 지정 포함)까지 지원하고, Google 캘린더 연동은 이번 범위에 넣지 않는다(OAuth 스코프 확장, REST API 직접 호출, 양방향 동기화 충돌 처리 등 그 자체로 별도 작업량).

## 2. 데이터 모델

```sql
create table calendar_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  title text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  recurrence_rule text, -- null = 단일 일정. 'DAILY' / 'WEEKLY:MO,WE,FR' / 'MONTHLY' / 'YEARLY'
  created_by uuid not null references household_members(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table calendar_events enable row level security;

create policy "members can select calendar_events" on calendar_events for select using (is_household_member(household_id));
create policy "members can insert calendar_events" on calendar_events for insert with check (is_household_member(household_id));
create policy "members can update calendar_events" on calendar_events for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete calendar_events" on calendar_events for delete using (is_household_member(household_id));
```

- 권한: 가구 구성원 누구나 모든 일정을 조회/수정/삭제 가능 (거래/예산 등 기존 테이블과 동일한 정책 — 부부가 하나의 장부/캘린더를 공유하는 이 앱의 기본 철학과 일치).
- `recurrence_rule`이 있는 일정을 수정/삭제하면 **반복 규칙 전체(=그 일정)**가 바뀐다. "이 날짜만 예외 처리"하는 개별 발생(occurrence) 단위 수정/삭제는 지원하지 않는다 — 필요하면 반복을 지우고 개별로 다시 등록하는 것으로 충분하다고 판단해 확정(예외 목록을 관리하려면 데이터 모델이 꽤 복잡해지는데, 그 비용을 들일 만한 실사용 필요가 없다고 판단).
- 반복 종료일 없음(무기한 반복 허용) — `until` 컬럼을 두지 않는다.

## 3. 반복 일정 계산

무기한 반복을 개별 행으로 미리 생성해두지 않는다. `recurrence_rule`은 룰 자체만 저장하고, 캘린더 화면에 보이는 달(±1개월 여유) 범위 안에서 발생 날짜를 그때그때 순수 Dart 함수로 계산한다.

**형식:**
- `null` — 단일 일정, `start_at` 하루(또는 `start_at`~`end_at` 구간)만 발생
- `DAILY` — `start_at`부터 매일
- `WEEKLY:MO,WE,FR` — 지정된 요일마다 (요일 코드는 `MO,TU,WE,TH,FR,SA,SU`)
- `MONTHLY` — `start_at`과 같은 날짜(day-of-month)로 매달
- `YEARLY` — `start_at`과 같은 월/일로 매년

**엣지 케이스:** `MONTHLY`로 예를 들어 1월 31일에 시작한 반복 일정은, 31일이 없는 달(2월, 4월 등)엔 그 달의 발생을 건너뛴다(day-of-month를 그 달의 마지막 날로 당기지 않음 — 가장 단순하고 예측 가능한 동작).

**계산 함수는 순수 Dart 함수**(위젯/네트워크 의존 없음)로 만들어 유닛 테스트로 검증한다 — 이번 Phase 4의 `buildTransactionsCsv`와 같은 패턴.

각 발생(occurrence)의 길이는 원본 일정의 `end_at - start_at` 기간을 그대로 유지한다 — 발생 날짜가 바뀌어도 지속 시간은 고정.

## 4. 화면/UI

**캘린더 화면 (`lib/features/calendar/calendar_screen.dart`, 신규):**
- `table_calendar` 패키지로 월간 그리드
- 화면에 보이는 달(±1개월)의 `calendar_events`를 전부 불러와 반복 계산 함수로 발생 날짜를 펼친 뒤 `eventLoader`에 채움 — 일정 있는 날짜에 점 표시
- 날짜를 탭하면 그날의 일정 목록이 캘린더 아래에 나열 (표준 `table_calendar` 패턴)
- FAB로 일정 추가

**일정 작성/수정 화면 (`calendar_event_form_screen.dart`, 신규):**
- 제목, 날짜, 종일/시간 지정 토글(시간 지정 시 시작·종료 시간 선택), 반복 규칙 선택(없음/매일/매주-요일선택/매월/매년)
- 수정 화면엔 삭제 버튼 + 확인 다이얼로그 (반복 일정 삭제는 규칙 전체가 사라진다는 걸 다이얼로그 문구에 명시)

**홈 화면:**
- "캘린더" 메뉴 항목 추가 → `CalendarScreen`으로 이동

## 5. 에러/엣지 케이스

- 종료 시각이 시작 시각보다 이전인 경우 저장 전 검증 (기존 거래 폼의 금액 검증과 같은 자리에서 처리)
- 반복 규칙 파싱 실패(형식이 깨진 문자열) 시 해당 일정을 조용히 누락시키지 않고, 단일 일정처럼 `start_at` 하루만 표시 (계산 함수의 안전한 폴백)
- 삭제된 일정을 만든 구성원이 나중에 "탈퇴"해도 `created_by`는 `on delete restrict`로 막혀 있는 `household_members` 참조이므로, 기존 거래/계좌와 동일하게 구성원 탈퇴 시에도 데이터가 깨지지 않는다(구성원 자체는 삭제되지 않고 `left_at`만 세팅되는 기존 정책과 일치).

## 6. 테스트 계획

- SQL 테스트 (`supabase/tests/0008_calendar_events_test.sql`, 기존 `begin/rollback + savepoint` 패턴): RLS가 다른 household의 일정을 못 보게 막는지
- Dart 리포지토리 테스트 (실제 `SupabaseClient` + 로컬 `HttpServer` 패턴): `CalendarEventRepository`의 list/create/update/delete
- 반복 계산 순수 함수 유닛 테스트: DAILY/WEEKLY(요일 지정)/MONTHLY(월말 엣지 케이스 포함)/YEARLY/null(단일 일정) 각각, 그리고 지정된 날짜 범위 밖 발생은 제외되는지

## 7. 범위 밖 (이번 Phase에서 제외)

- Google 캘린더 양방향 동기화 — 별도 Phase
- 반복 일정의 개별 발생(occurrence) 단위 예외 수정/삭제 — 확정적으로 제외 (다시 필요해질 가능성 낮다고 판단)
- 거래-일정 자동 연동 — 상위 스펙에서도 MVP 범위 밖으로 명시됨
- 반복 종료일 지정 — 무기한 반복만 지원
