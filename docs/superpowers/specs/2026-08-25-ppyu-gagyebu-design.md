# 쀼가계부 — 부부 공유 가계부 + 캘린더 앱 설계 (MVP)

## 1. 개요

부부(추후 3~4인 확장 가능)가 초대 코드/QR/딥링크로 서로 계정을 연동해 하나의 가계부와 캘린더를 함께 쓰는 모바일 앱. 현재는 두 사람 전용이지만, 향후 다른 사용자들도 쓰는 공개 서비스로 확장할 것을 전제로 설계한다(MVP는 무료, 사용자 수 증가에도 비용이 예측 가능하게 스케일되는 구조 선택).

## 2. 범위

### MVP에 포함
- Android 단일 플랫폼 (iOS는 다음 단계)
- 카카오 / 구글 소셜로그인
- 초대 코드 + QR + 딥링크 혼합 방식의 부부 연동 (2인 고정, 스키마는 3~4인 확장 가능하게)
- 카드결제 문자 자동인식 등록 (Android SMS 파싱)
- 카테고리 분류, 반복거래 자동등록
- 예산 설정 + 초과 알림, 저축 목표, 다중 계좌/카드 관리
- 월간/연간 통계 그래프, 입력자 표시, CSV/엑셀 내보내기, 태그/메모/검색
- 규칙 기반 소비 절감 추천 (전월 대비 카테고리 증감률)
- 예산초과 알림, 정기결제 리마인더 (푸시)
- 공유 캘린더: 기본 일정 등록/공유, 반복 일정, 기기 기본 캘린더(Google) 동기화

### MVP 이후로 명확히 미룸
- iOS 지원, Apple 로그인
- OCR 영수증 인식, 영수증 사진 첨부
- 정산(더치페이 계산) 기능
- 오픈뱅킹/카드사 공식 API 연동 (사업자 등록·금융권 심사 필요)
- AI(LLM) 기반 개인화 추천
- 3~4인 그룹 확장 UI
- 오프라인 입력 큐 (MVP는 온라인 전제)
- 일정-가계부 연동(지출 예정 일정과 거래 자동 연결)

## 3. 기술 스택

- **클라이언트**: Flutter (Android 단일 타겟으로 시작, 추후 iOS 빌드 추가 용이)
- **백엔드**: Supabase (Postgres + Auth + Realtime)
  - 선택 이유: 가계부 데이터는 집계/리포트 쿼리가 핵심이라 관계형 DB가 유리, 무료 티어로 MVP 가능, 사용자 증가 시 요금 예측 가능, 오픈소스라 락인 회피
- **푸시 알림**: Firebase Cloud Messaging (Supabase Edge Function이 조건 체크 후 트리거)
- **인증**: 구글은 Supabase 기본 OAuth 제공자 사용. 카카오는 Supabase 기본 제공자 목록에 없어 별도 처리 필요 — 클라이언트에서 Kakao SDK로 로그인 후 액세스 토큰을 Supabase Edge Function으로 보내 카카오 API로 검증, 검증 성공 시 Supabase 커스텀 세션(JWT) 발급.

## 4. 데이터 모델 (핵심 테이블)

- `households` — 부부 그룹 (id, name, created_at)
- `household_members` — 그룹 구성원 (household_id, user_id, role, joined_at, left_at) — 인원 확장을 코드 변경 없이 지원하도록 별도 테이블로 분리
- `invite_codes` — 초대 코드 (household_id, code, expires_at, used_at, created_by) — 1회용, 시간 제한
- `accounts` — 계좌/카드 (household_id, owner_member_id, name, type)
- `categories` — 카테고리 (household_id, name, icon, is_default)
- `transactions` — 거래 (household_id, account_id, member_id, category_id, amount, type, memo, tags, occurred_at, source: manual|sms_auto, created_at)
- `recurring_transactions` — 반복거래 템플릿 (household_id, account_id, category_id, amount, interval_rule, next_run_at)
- `budgets` — 예산 (household_id, category_id nullable, month, amount)
- `savings_goals` — 저축 목표 (household_id, name, target_amount, current_amount, target_date)
- `calendar_events` — 공유 일정 (household_id, title, start_at, end_at, recurrence_rule, created_by)

## 5. 기능별 처리 방식

### 카드결제 자동등록 (Android)
기기 내에서 문자 내용을 정규식으로 파싱해 금액/가맹점/카드사/날짜를 추출한다. **원문 문자는 서버로 전송하지 않고**, 파싱된 구조화 데이터만 사용자 1차 확인 후 서버에 저장한다 (프라이버시 보호). 파싱 실패(미지원 카드사 포맷 등) 시 조용히 누락시키지 않고 수동입력 화면으로 유도한다.

### 소비 절감 추천
서버(Postgres 함수)에서 이번 달 카테고리별 지출을 전월과 비교해 증감률을 계산하고, 임계치(기본 +20%) 초과 카테고리 상위 2~3개를 홈/리포트 화면에 노출한다. 외부 API 호출 없음.

### 예산초과/정기결제 알림
Supabase Edge Function이 주기적으로(또는 트리거 기반) 예산 소진율과 반복거래 예정일을 체크해 FCM으로 푸시 발송.

### 공유 캘린더
기본 CRUD + 반복 일정 지원. 기기 기본(Google) 캘린더와 양방향 동기화. 거래-일정 자동 연동은 MVP 범위 밖.

## 6. 기본값으로 확정한 결정

1. 부부가 각자 다른 카드를 써도 하나의 통합 장부로 합쳐진다 (개인 지갑 분리 없음).
2. 배우자가 연동을 해제해도 기존 거래 기록은 삭제하지 않고 보존한다 (구성원 상태만 "탈퇴"로 표시).
3. MVP는 온라인 연결을 전제로 하며, 오프라인 입력 큐는 다음 단계 과제.
4. 통화는 원화(KRW) 단일 통화.

## 7. 에러/엣지 케이스

- 초대 코드: 만료 시간 경과 또는 이미 사용된 코드 재사용 시도 → 명확한 오류 메시지, 새 코드 재발급 유도
- 그룹 인원: 현재 2명 고정이므로 이미 2명인 그룹에 3번째 초대 코드 사용 시도 → 차단 (스키마는 확장 대비되어 있으나 MVP UI에서는 막음)
- SMS 파싱 실패 → 수동입력으로 폴백, 데이터 유실 없음
- 소셜로그인 실패/취소 → 로그인 화면으로 복귀, 상태 유지 안 함

## 8. 테스트 계획

구현 단계(별도 implementation plan)에서 TDD로 진행. 핵심 검증 대상: 초대 코드 발급/만료/1회성 로직, SMS 파싱 정규식(카드사별 샘플 문자 기반), 예산 증감률 계산 로직, 반복거래 다음 실행일 계산 로직.
