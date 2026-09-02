# 반복거래·자동인식 거래 "확인 후 등록" 재설계

> 이 문서는 `docs/superpowers/specs/2026-08-27-recurring-transactions-design.md`의 "소급 생성 메커니즘"(섹션 3)을 대체한다. 데이터 모델(섹션 2)과 화면 목록(섹션 4)의 반복거래 관리 화면 부분도 이 문서 기준으로 갱신된다. 알림 자동인식(Phase 3, `docs/superpowers/specs/2026-08-25-ppyu-gagyebu-design.md`의 "카드결제 자동등록") 쪽도 이 문서에서 확장한다.

## 1. 배경 — 왜 재설계하는가

`recurring-transactions` 브랜치(아직 main에 merge 안 됨)에 이미 구현된 "앱 접속 시 자동 소급 생성" 방식은, 최종 리뷰에서 실제 동시성 버그(부부가 같은 날 각자 앱을 열면 밀린 거래 전체가 중복 생성될 수 있음)가 발견되어 compare-and-swap으로 막았다. 그런데 그 수정을 논의하는 과정에서, 애초에 "완전 자동·조용한 생성" 대신 "확인 후 등록하는 투두리스트" 방식이 이 앱의 "부부가 각자 쓴 건 각자 등록" 철학에 더 맞고, 동시성 문제도 방어적 코드(CAS) 없이 DB 제약만으로 원천 차단된다는 게 명확해졌다. 이 문서는 그 재설계를 다룬다.

**핵심 결정: 반복거래는 "확인 후 등록"이 새 기본 철학이지만, 원하면 템플릿마다 "자동 등록"도 선택 가능하다.** 알림 자동인식도 같은 확인/자동 개념을 도입하되, 메커니즘은 반복거래와 다르다(아래 섹션 3 참조 — 알림은 예측 가능한 일정이 없어서 반복거래와 같은 "빠진 발생 계산" 방식을 쓸 수 없다).

## 2. 데이터 모델

**`recurring_transactions` 컬럼 변경 (0010 마이그레이션 자체를 아직 push 안 했다면 그 파일을 고치고, 이미 push했다면 새 마이그레이션으로):**

```sql
alter table recurring_transactions
  add column owner_member_id uuid not null references household_members(id) on delete restrict,
  add column auto_register boolean not null default false;

alter table recurring_transactions rename column next_run_at to start_at;
```

- `owner_member_id`: 이 반복거래가 "누구 소비인지" — `created_by`(누가 템플릿을 만들었는지)와는 별개 개념. 배우자가 대신 등록해줄 수도 있으므로 분리.
- `auto_register`: `true`면 기존처럼 홈 화면 진입 시 자동 생성, `false`(기본값)면 확인 후 등록(투두리스트) 대상.
- `start_at`(구 `next_run_at`): 이제 "다음 실행 예정일"로 계속 갱신되는 값이 아니라, 발생 날짜를 계산하는 **고정된 기준일**(최초 시작일)이다 — 아래 섹션 3에서 왜 더 이상 갱신할 필요가 없는지 설명.

insert RLS 정책도 `owner_member_id`가 같은 가구 소속인지 검증하도록 확장(기존 `created_by` 검증과 같은 패턴):
```sql
drop policy "members can insert recurring_transactions" on recurring_transactions;
create policy "members can insert recurring_transactions" on recurring_transactions for insert with check (
  is_household_member(household_id)
  and exists (select 1 from household_members m where m.id = created_by and m.household_id = recurring_transactions.household_id)
  and exists (select 1 from household_members m where m.id = owner_member_id and m.household_id = recurring_transactions.household_id)
);
```

**`transactions` 컬럼 추가:**

```sql
alter table transactions
  add column recurring_transaction_id uuid references recurring_transactions(id) on delete set null,
  add column confirmed boolean not null default true;

create unique index transactions_recurring_occurrence_unique
  on transactions (recurring_transaction_id, occurred_at)
  where recurring_transaction_id is not null;
```

- `recurring_transaction_id`: 이 거래가 어느 반복거래 템플릿의 발생인지. `on delete set null`이라 템플릿을 삭제해도 과거 거래는 안 사라짐(기존 설계 원칙 그대로).
- **`(recurring_transaction_id, occurred_at)` 부분 유니크 인덱스가 이 재설계의 핵심.** 같은 템플릿의 같은 발생 날짜는 DB가 원천적으로 중복 저장을 막아준다 — 두 세션이 동시에 같은 발생을 처리해도 먼저 들어간 것만 성공하고 나중 것은 유니크 위반으로 실패(앱에서 그냥 무시하면 됨). **이 재설계로 기존 `advanceNextRunAt`의 compare-and-swap 로직 전체가 불필요해지고 삭제된다.**
- `confirmed`: 기본값 `true`(기존 수동입력/자동등록 거래는 전부 이미 "확인됨" 상태). 알림 자동인식이 "확인 후 저장" 모드일 때만 `false`로 생성되고, 사용자가 확인하면 `true`로 바뀐다. `transaction_list_screen.dart`의 기본 목록은 `confirmed = true`인 것만 보여준다(미확인 항목은 별도 투두 화면에서만 보임).

## 3. 반복거래 — 발생 계산 및 등록 메커니즘

**"밀린 발생 목록" 계산 (순수 함수, 서버 스케줄러 없음, 기존과 동일):**
1. 템플릿의 `start_at`부터 `interval_rule`을 반복 적용하며 오늘(now)까지의 모든 발생 날짜를 나열한다(캘린더 phase의 `expandOccurrences`와 유사하지만, 이 문서 섹션 4에서 다시 설명하듯 이 함수는 재사용하지 않고 작게 새로 만든다).
2. `transactions`에서 `recurring_transaction_id = 이 템플릿, occurred_at = 그 날짜`인 행이 이미 있는 발생은 제외한다.
3. 남은 게 "미완료 발생" 목록이다.

**이 계산 하나로 두 모드를 모두 처리한다:**
- **`auto_register = true`**: 홈 화면 진입 시(기존과 동일하게 fire-and-forget), 미완료 발생 각각에 대해 `recurring_transaction_id`/`occurred_at`을 채우고 `member_id`는 템플릿의 `owner_member_id`로 고정해 거래를 INSERT 시도한다. 유니크 인덱스가 중복을 막아주므로, 인덱스 위반 에러는 조용히 무시하고 다음 발생으로 넘어간다(다른 세션이 먼저 처리한 경우). 안전장치로 템플릿당 이번 체크에서 최대 60건까지만 생성(기존과 동일한 상한 — 무한/과도 생성 방지 목적이지 동시성 방어 목적이 더 이상 아님).
- **`auto_register = false`**: 미완료 발생을 투두리스트 화면에 그대로 나열한다. 사용자가 항목을 탭해서 완료 처리하면 그 발생 날짜로 거래를 INSERT한다(같은 유니크 인덱스가 보호). `member_id`는 **템플릿의 `owner_member_id`로 고정** — 배우자가 대신 눌러서 완료 처리해도, 그 소비는 여전히 원래 주인 앞으로 기록된다(누가 "처리"했는지와 "누구 소비인지"는 다른 개념).

**`start_at`을 더 이상 갱신하지 않는 이유:** 완료 여부를 "거래가 실제로 존재하는지"로 판단하므로, 별도의 "다음 실행 예정일" 포인터를 유지·전진시킬 필요가 없다. 발생 계산은 항상 `start_at`(고정)부터 오늘까지 전부 다시 계산하고, 이미 처리된 건 유니크 인덱스 존재 여부로 자동 필터링된다.

## 4. 화면/네비게이션

**홈 화면에 "자동거래등록" 상위 메뉴** 추가, 하위 서브메뉴 2개.

### ① 반복거래

진입 시 상단 탭 [처리할 목록 | 템플릿 관리].

**처리할 목록 (투두리스트, `lib/features/ledger/recurring_transaction_todo_screen.dart`, 신규):**
- 상단 탭 [나 | 배우자], 기본은 "나"(현재 로그인한 사용자의 `member_id`와 `owner_member_id`가 일치하는 템플릿들의 미완료 발생) 먼저 보임.
- `auto_register = false`인 템플릿들의 미완료 발생을 각각 별도 항목으로 나열 (예: "월세 - 9월", "월세 - 10월") — 발생 날짜 오름차순.
- 항목 탭 → 확인 다이얼로그("이 거래를 등록할까요? 계좌: OO, 금액: OO원") → 확인 시 거래 INSERT.
- 배우자 탭에서도 동일 UI, 다른 사람의 미완료 발생을 대신 처리 가능. 완료되면 유니크 인덱스 덕분에 자동으로 양쪽 탭 모두에서 사라짐(다음에 목록을 다시 불러올 때).

**템플릿 관리 (`recurring_transaction_screen.dart`, 기존 화면 수정):**
- 기존 CRUD 화면 그대로, 폼에 필드 2개 추가: "소유자"(나/배우자 선택 — 가구 구성원 목록에서 고름), "자동 등록"(스위치, 기본 꺼짐 = 확인 후 등록).
- 목록 화면에 "자동"/"확인 후" 배지를 항목마다 표시해서 한눈에 구분되게 한다.

### ② 자동인식 거래

- 기존 "결제 알림 자동인식 설정"(`notification_onboarding_screen.dart`)을 이 서브메뉴 아래로 이동.
- 새 로컬 설정(기기별, `SharedPreferences` — 가구 공유 아님, 알림은 이 기기에서만 오므로): "알림 오면 바로 저장"(기본값, 기존 동작) vs "확인 후 저장".
- "확인 후 저장" 켜면 `NotificationAutoSaveService`가 거래를 `confirmed = false`로 생성(즉시 만들어지긴 하지만 목록엔 안 보임 — 알림은 예측 가능한 일정이 없어서 반복거래처럼 "빠진 걸 계산"할 수 없고, 이벤트 자체가 유일한 근거이므로 일단 만들어두고 확인 플래그로 구분하는 방식을 쓴다).
- 이 서브메뉴 안에 새 화면(`notification_pending_screen.dart`, 신규): `confirmed = false`인 거래 목록. 탭하면 상세 확인 후 "확인" 버튼으로 `confirmed = true`로 갱신 (또는 필요시 수정 후 확인).

**거래 목록 화면(`transaction_list_screen.dart`) 변경:** 기본 조회에 `confirmed = true` 필터 추가 — 미확인 알림 거래는 이 목록에 안 보이고 전용 대기 화면에서만 보인다.

## 5. 에러/엣지 케이스

- 유니크 인덱스 위반(동시 처리 경합) — 앱에서 해당 INSERT 실패를 조용히 무시하고 계속 진행(자동모드는 다음 발생으로, 확인모드는 사용자에게 "이미 처리됐어요" 정도의 짧은 안내 후 목록 새로고침).
- 자동모드 60건 상한은 기존과 동일하게 유지(과도 생성 방지 안전장치, 동시성 방어 목적은 아님).
- 템플릿의 `owner_member_id`를 나중에 바꾸면(예: 원래 내 것으로 등록했다가 배우자 것으로 정정) 이미 생성된 과거 거래의 `member_id`는 소급 변경하지 않는다 — 그 시점 이후 새로 계산되는 미완료 발생부터 새 소유자 기준으로 표시.
- 알림 확인모드에서 `confirmed = false`인 거래가 쌓여만 있고 사용자가 안 열어보면? — 스펙 범위 밖(뱃지/알림 등 재촉 기능은 나중에 필요하면 추가).

## 6. 테스트 계획

- SQL 테스트: 유니크 인덱스가 실제로 중복 삽입을 막는지, insert RLS가 `owner_member_id` 가구 소속도 검증하는지.
- Dart 순수 함수 테스트: 발생 계산(빠진 날짜 골라내기)이 각 규칙 타입별로 정확한지, 이미 처리된 발생을 정확히 제외하는지.
- 리포지토리/서비스 테스트: 자동모드 INSERT가 유니크 위반 시 에러를 삼키고 계속 진행하는지(기존 `notification_auto_save_service`류 패턴과 동일하게 실제 `HttpServer`로 검증).
- UI: 나/배우자 탭 전환, 완료 처리 후 목록에서 사라지는지(수동 확인 수준, 위젯 테스트 인프라 없음 — 기존 프로젝트 컨벤션 그대로).

## 7. 범위 밖 (이번 재설계에서 제외)

- 알림 확인모드의 "밀린 미확인 항목 알림/뱃지" — 나중 과제.
- 반복거래 발생 단위 개별 예외 처리(캘린더/기존 반복거래 스펙과 동일하게 계속 제외).
- `recurring_transactions.owner_member_id`를 3인 이상 가구로 확장하는 것 — 이 앱은 2인 고정이므로 범위 밖.
