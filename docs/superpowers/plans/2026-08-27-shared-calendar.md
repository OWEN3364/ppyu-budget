# 공유 캘린더 (코어) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 가구 구성원이 공유하는 일정을 등록·조회·수정·삭제하고, 요일 지정 포함 반복 일정을 지원한다. Google 캘린더 동기화는 범위 밖.

**Architecture:** `calendar_events` 테이블에 반복 규칙 자체만 저장하고(무기한 반복도 개별 행으로 미리 만들지 않음), 화면에 보이는 달 범위 안에서만 순수 Dart 함수로 발생 날짜를 계산해서 표시한다. 월간 그리드는 `table_calendar` 패키지, 작성/수정은 한 화면(모드로 분기)에서 처리.

**Tech Stack:** Flutter (Android), Supabase (Postgres+RLS+PostgREST), `table_calendar`(신규 의존성)

**Spec:** `docs/superpowers/specs/2026-08-27-shared-calendar-design.md`

## Global Constraints

- Android 단일 타겟.
- 모든 리포지토리 테스트는 실제 `SupabaseClient` + 로컬 `HttpServer`로 검증 (mocktail로 `.from()`/`.rpc()` 직접 모킹 금지).
- 새 테이블은 `alter table ... enable row level security` 포함, 기존 `is_household_member(household_id)` 패턴 그대로 재사용 (이 테이블엔 SECURITY DEFINER 함수가 필요 없음 — 단순 CRUD라 RLS 정책만으로 충분).
- 모든 async 위젯 메서드는 await 이후 `setState` 전에 `mounted` 체크, 저장/삭제류는 busy-guard bool로 중복 실행 방지.
- 파괴적 작업(삭제)엔 확인 다이얼로그 필수 — Phase 4 최종 리뷰에서 태그 삭제 확인 다이얼로그가 스펙에 있었는데 계획 단계에서 빠뜨렸던 걸 잡은 적이 있음, 이번엔 처음부터 넣는다.
- `table_calendar`는 새 의존성이다 — 정확한 API는 버전마다 다를 수 있으니, 구현자는 `flutter pub add`로 실제 버전을 받은 뒤 설치된 패키지 소스(pub cache)나 README를 직접 확인하고 정확한 시그니처로 작성한다. 이 문서의 예시 코드는 출발점이지, 검증 없이 그대로 쓸 코드가 아니다.
- 에러 메시지는 기존처럼 한국어, 사용자가 할 일 위주로 짧게.

---

### Task 1: 스키마 — calendar_events

**Files:**
- Create: `supabase/migrations/0008_calendar_events.sql`
- Test: `supabase/tests/0008_calendar_events_test.sql`

**Interfaces:**
- Produces: `calendar_events(id, household_id, title, start_at, end_at, all_day, recurrence_rule, created_by, created_at)`

- [ ] **Step 1: 마이그레이션 작성**

```sql
create table calendar_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  title text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  recurrence_rule text,
  created_by uuid not null references household_members(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table calendar_events enable row level security;

create policy "members can select calendar_events" on calendar_events for select using (is_household_member(household_id));
create policy "members can insert calendar_events" on calendar_events for insert with check (is_household_member(household_id));
create policy "members can update calendar_events" on calendar_events for update using (is_household_member(household_id)) with check (is_household_member(household_id));
create policy "members can delete calendar_events" on calendar_events for delete using (is_household_member(household_id));
```

- [ ] **Step 2: 적용**

Run: `npx --yes supabase db push --linked`

- [ ] **Step 3: SQL 테스트 작성**

기존 `supabase/tests/0005_tags_nickname_test.sql`와 동일한 `begin;`/`savepoint`/`rollback to savepoint` 패턴, `set local role authenticated;`는 파일당 한 번만 최상단에(어떤 `do $$ $$` 블록 안도 아님).

```sql
-- Run with: supabase db query --linked --file supabase/tests/0008_calendar_events_test.sql
begin;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'b@test.com')
  on conflict do nothing;

set local role authenticated;

-- a household's calendar events are invisible to a non-member
savepoint sp1;
do $$
declare
  v_household_a uuid;
  v_household_b uuid;
  v_member_a uuid;
  v_event_id uuid;
  v_count integer;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_a := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_a and user_id = auth.uid();
  insert into calendar_events (household_id, title, start_at, end_at, created_by)
  values (v_household_a, '병원 예약', now(), now() + interval '1 hour', v_member_a)
  returning id into v_event_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  v_household_b := create_household_and_owner();
  select count(*) into v_count from calendar_events where id = v_event_id;
  if v_count != 0 then
    raise exception 'TEST FAILED: household B could see household A''s calendar event';
  end if;
end $$;
rollback to savepoint sp1;

-- any member of the SAME household can update/delete an event created by another member
savepoint sp2;
do $$
declare
  v_household_id uuid;
  v_member_a uuid;
  v_invite_code text;
  v_event_id uuid;
  v_title text;
begin
  perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  v_household_id := create_household_and_owner();
  select id into v_member_a from household_members where household_id = v_household_id and user_id = auth.uid();
  v_invite_code := create_invite_code(v_household_id);
  insert into calendar_events (household_id, title, start_at, end_at, created_by)
  values (v_household_id, '원래 제목', now(), now() + interval '1 hour', v_member_a)
  returning id into v_event_id;

  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222"}', true);
  perform join_household(v_invite_code);
  update calendar_events set title = '수정된 제목' where id = v_event_id;

  select title into v_title from calendar_events where id = v_event_id;
  if v_title != '수정된 제목' then
    raise exception 'TEST FAILED: expected a household-mate to be able to update the event, got %', v_title;
  end if;
end $$;
rollback to savepoint sp2;

rollback;
```

- [ ] **Step 4: 테스트 실행**

Run: `npx --yes supabase db query --linked --file supabase/tests/0008_calendar_events_test.sql`
Expected: 에러 없이 종료

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0008_calendar_events.sql supabase/tests/0008_calendar_events_test.sql
git commit -m "feat(db): add calendar_events table with household-shared RLS"
```

---

### Task 2: CalendarEvent 모델 + CalendarEventRepository

**Files:**
- Create: `lib/features/calendar/models/calendar_event.dart`
- Create: `lib/features/calendar/calendar_event_repository.dart`
- Test: `test/features/calendar/calendar_event_repository_test.dart`

**Interfaces:**
- Produces: `CalendarEvent{id, title, startAt, endAt, allDay, recurrenceRule, createdBy}`, `CalendarEventRepository.list(householdId)`, `.create({...})`, `.update({...})`, `.delete(id)`

- [ ] **Step 1: 모델**

`lib/features/calendar/models/calendar_event.dart`:
```dart
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.allDay,
    required this.createdBy,
    this.recurrenceRule,
  });

  final String id;
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;
  final String createdBy;
  final String? recurrenceRule;

  factory CalendarEvent.fromJson(Map<String, dynamic> json) => CalendarEvent(
        id: json['id'] as String,
        title: json['title'] as String,
        startAt: DateTime.parse(json['start_at'] as String),
        endAt: DateTime.parse(json['end_at'] as String),
        allDay: json['all_day'] as bool,
        createdBy: json['created_by'] as String,
        recurrenceRule: json['recurrence_rule'] as String?,
      );
}
```

- [ ] **Step 2: CalendarEventRepository**

`lib/features/calendar/calendar_event_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/calendar/models/calendar_event.dart';

class CalendarEventRepository {
  CalendarEventRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<CalendarEvent>> list(String householdId) async {
    final rows = await _client.from('calendar_events').select().eq('household_id', householdId);
    return rows.map(CalendarEvent.fromJson).toList();
  }

  Future<CalendarEvent> create({
    required String householdId,
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    required bool allDay,
    required String createdBy,
    String? recurrenceRule,
  }) async {
    final rows = await _client.from('calendar_events').insert({
      'household_id': householdId,
      'title': title,
      'start_at': startAt.toUtc().toIso8601String(),
      'end_at': endAt.toUtc().toIso8601String(),
      'all_day': allDay,
      'created_by': createdBy,
      'recurrence_rule': recurrenceRule,
    }).select();
    return CalendarEvent.fromJson(rows.first);
  }

  Future<CalendarEvent> update({
    required String id,
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    required bool allDay,
    String? recurrenceRule,
  }) async {
    final rows = await _client
        .from('calendar_events')
        .update({
          'title': title,
          'start_at': startAt.toUtc().toIso8601String(),
          'end_at': endAt.toUtc().toIso8601String(),
          'all_day': allDay,
          'recurrence_rule': recurrenceRule,
        })
        .eq('id', id)
        .select();
    return CalendarEvent.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('calendar_events').delete().eq('id', id);
  }
}
```

- [ ] **Step 3: 리포지토리 테스트**

`test/features/calendar/calendar_event_repository_test.dart` (기존 `transaction_repository_test.dart`/`tag_repository_test.dart`와 동일한 `HttpServer` 패턴):
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/calendar/calendar_event_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late CalendarEventRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = CalendarEventRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s calendar events', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/calendar_events'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'evt-1',
          'title': '병원 예약',
          'start_at': '2026-09-01T00:00:00.000Z',
          'end_at': '2026-09-01T01:00:00.000Z',
          'all_day': false,
          'created_by': 'member-1',
          'recurrence_rule': null,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.title, '병원 예약');
    expect(result.first.recurrenceRule, isNull);
  });

  test('create posts a new event with recurrence rule', () async {
    final future = repo.create(
      householdId: 'household-1',
      title: '운동',
      startAt: DateTime.utc(2026, 9, 1, 7),
      endAt: DateTime.utc(2026, 9, 1, 8),
      allDay: false,
      createdBy: 'member-1',
      recurrenceRule: 'WEEKLY:MO,WE,FR',
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'title': '운동',
      'start_at': '2026-09-01T07:00:00.000Z',
      'end_at': '2026-09-01T08:00:00.000Z',
      'all_day': false,
      'created_by': 'member-1',
      'recurrence_rule': 'WEEKLY:MO,WE,FR',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'evt-2',
          'title': '운동',
          'start_at': '2026-09-01T07:00:00.000Z',
          'end_at': '2026-09-01T08:00:00.000Z',
          'all_day': false,
          'created_by': 'member-1',
          'recurrence_rule': 'WEEKLY:MO,WE,FR',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.recurrenceRule, 'WEEKLY:MO,WE,FR');
  });

  test('delete removes an event by id', () async {
    final future = repo.delete('evt-1');

    final request = await mockServer.first;
    expect(request.method, 'DELETE');
    expect(request.uri.queryParameters['id'], 'eq.evt-1');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });
}
```

- [ ] **Step 4: 테스트 실행**

Run: `flutter test test/features/calendar/calendar_event_repository_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/features/calendar/models/calendar_event.dart lib/features/calendar/calendar_event_repository.dart test/features/calendar/calendar_event_repository_test.dart
git commit -m "feat(calendar): add CalendarEvent model and repository"
```

---

### Task 3: 반복 일정 발생(occurrence) 계산 순수 함수

**Files:**
- Create: `lib/features/calendar/recurrence.dart`
- Test: `test/features/calendar/recurrence_test.dart`

**Interfaces:**
- Consumes: `CalendarEvent`(Task 2)
- Produces: `Occurrence{start, end}`, `List<Occurrence> expandOccurrences(CalendarEvent event, DateTime rangeStart, DateTime rangeEnd)`

- [ ] **Step 1: 계산 함수**

`lib/features/calendar/recurrence.dart`:
```dart
import 'package:ppyu_budget/features/calendar/models/calendar_event.dart';

class Occurrence {
  const Occurrence({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

const _weekdayCodes = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

/// Expands [event] into its actual occurrences within
/// `[rangeStart, rangeEnd]` (inclusive). Recurring events are never
/// materialized as DB rows — this runs at display time against whatever
/// range the calendar screen currently shows.
List<Occurrence> expandOccurrences(CalendarEvent event, DateTime rangeStart, DateTime rangeEnd) {
  final duration = event.endAt.difference(event.startAt);
  Occurrence occ(DateTime start) => Occurrence(start: start, end: start.add(duration));
  bool inRange(DateTime start) => !start.isBefore(rangeStart) && !start.isAfter(rangeEnd);

  final rule = event.recurrenceRule;
  if (rule == null) {
    return inRange(event.startAt) ? [occ(event.startAt)] : [];
  }

  final results = <Occurrence>[];

  if (rule == 'DAILY') {
    // ponytail: walks day-by-day from the event's original start date
    // instead of skipping ahead to rangeStart. Fine at household-calendar
    // scale (a handful of years back at most); if this ever needs to
    // support decades-old daily recurrences cheaply, jump straight to the
    // first in-range day with date arithmetic instead of iterating.
    var cursor = event.startAt;
    while (!cursor.isAfter(rangeEnd)) {
      if (inRange(cursor)) results.add(occ(cursor));
      cursor = cursor.add(const Duration(days: 1));
    }
    return results;
  }

  if (rule.startsWith('WEEKLY:')) {
    final days = rule.substring(7).split(',').map((c) => _weekdayCodes[c]).whereType<int>().toSet();
    var cursor = event.startAt;
    while (!cursor.isAfter(rangeEnd)) {
      if (days.contains(cursor.weekday) && inRange(cursor)) results.add(occ(cursor));
      cursor = cursor.add(const Duration(days: 1));
    }
    return results;
  }

  if (rule == 'MONTHLY') {
    var year = event.startAt.year;
    var month = event.startAt.month;
    while (true) {
      // DateTime rolls an out-of-range day into the next month (e.g. day=31
      // in a 30-day month becomes the 1st of the month after) — checking
      // the constructed date's month/year against what we asked for is how
      // we detect and skip that "doesn't have this day" case, per spec.
      final candidate = DateTime(year, month, event.startAt.day, event.startAt.hour, event.startAt.minute);
      if (candidate.isAfter(rangeEnd)) break;
      if (candidate.month == month && candidate.year == year && inRange(candidate)) {
        results.add(occ(candidate));
      }
      month++;
      if (month > 12) {
        month = 1;
        year++;
      }
    }
    return results;
  }

  if (rule == 'YEARLY') {
    var year = event.startAt.year;
    while (true) {
      final candidate = DateTime(year, event.startAt.month, event.startAt.day, event.startAt.hour, event.startAt.minute);
      if (candidate.isAfter(rangeEnd)) break;
      if (inRange(candidate)) results.add(occ(candidate));
      year++;
    }
    return results;
  }

  // malformed/unknown rule: fall back to a single occurrence at start_at
  // rather than silently dropping the event, per spec.
  return inRange(event.startAt) ? [occ(event.startAt)] : [];
}
```

- [ ] **Step 2: 테스트**

`test/features/calendar/recurrence_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/calendar/models/calendar_event.dart';
import 'package:ppyu_budget/features/calendar/recurrence.dart';

CalendarEvent _event({required DateTime start, required DateTime end, String? rule}) =>
    CalendarEvent(id: 'e', title: 't', startAt: start, endAt: end, allDay: false, createdBy: 'm', recurrenceRule: rule);

void main() {
  final rangeStart = DateTime(2026, 9, 1);
  final rangeEnd = DateTime(2026, 9, 30, 23, 59, 59);

  test('null rule produces a single occurrence when inside range', () {
    final event = _event(start: DateTime(2026, 9, 10, 9), end: DateTime(2026, 9, 10, 10));
    final result = expandOccurrences(event, rangeStart, rangeEnd);
    expect(result, hasLength(1));
    expect(result.first.start, DateTime(2026, 9, 10, 9));
    expect(result.first.end, DateTime(2026, 9, 10, 10));
  });

  test('null rule produces nothing when outside range', () {
    final event = _event(start: DateTime(2026, 10, 1, 9), end: DateTime(2026, 10, 1, 10));
    expect(expandOccurrences(event, rangeStart, rangeEnd), isEmpty);
  });

  test('DAILY produces one occurrence per day within range', () {
    final event = _event(start: DateTime(2026, 9, 28, 8), end: DateTime(2026, 9, 28, 9), rule: 'DAILY');
    final result = expandOccurrences(event, rangeStart, rangeEnd);
    expect(result.map((o) => o.start.day), [28, 29, 30]);
  });

  test('WEEKLY:MO,WE,FR only produces occurrences on those weekdays', () {
    final event = _event(start: DateTime(2026, 9, 1, 7), end: DateTime(2026, 9, 1, 8), rule: 'WEEKLY:MO,WE,FR');
    final result = expandOccurrences(event, rangeStart, rangeEnd);
    for (final o in result) {
      expect([DateTime.monday, DateTime.wednesday, DateTime.friday], contains(o.start.weekday));
    }
    expect(result, isNotEmpty);
  });

  test('MONTHLY skips a month that does not have the day-of-month', () {
    // Jan 31 recurrence: Feb has no 31st, so Feb must be skipped entirely
    final event = _event(start: DateTime(2026, 1, 31, 10), end: DateTime(2026, 1, 31, 11), rule: 'MONTHLY');
    final result = expandOccurrences(event, DateTime(2026, 2, 1), DateTime(2026, 2, 28, 23, 59, 59));
    expect(result, isEmpty);
  });

  test('MONTHLY produces an occurrence for a month that does have the day', () {
    final event = _event(start: DateTime(2026, 1, 15, 10), end: DateTime(2026, 1, 15, 11), rule: 'MONTHLY');
    final result = expandOccurrences(event, rangeStart, rangeEnd);
    expect(result, hasLength(1));
    expect(result.first.start, DateTime(2026, 9, 15, 10));
  });

  test('YEARLY produces an occurrence only in the matching month/day', () {
    final event = _event(start: DateTime(2020, 9, 15, 10), end: DateTime(2020, 9, 15, 11), rule: 'YEARLY');
    final result = expandOccurrences(event, rangeStart, rangeEnd);
    expect(result, hasLength(1));
    expect(result.first.start, DateTime(2026, 9, 15, 10));
  });

  test('occurrence duration matches the original event duration', () {
    final event = _event(start: DateTime(2026, 9, 5, 10), end: DateTime(2026, 9, 5, 12, 30), rule: 'WEEKLY:SA');
    final result = expandOccurrences(event, rangeStart, rangeEnd);
    for (final o in result) {
      expect(o.end.difference(o.start), const Duration(hours: 2, minutes: 30));
    }
  });

  test('a malformed rule falls back to a single occurrence at start_at', () {
    final event = _event(start: DateTime(2026, 9, 10, 9), end: DateTime(2026, 9, 10, 10), rule: 'GARBAGE');
    final result = expandOccurrences(event, rangeStart, rangeEnd);
    expect(result, hasLength(1));
    expect(result.first.start, DateTime(2026, 9, 10, 9));
  });
}
```

- [ ] **Step 3: 테스트 실행**

Run: `flutter test test/features/calendar/recurrence_test.dart`
Expected: PASS (9 tests)

- [ ] **Step 4: Commit**

```bash
git add lib/features/calendar/recurrence.dart test/features/calendar/recurrence_test.dart
git commit -m "feat(calendar): add pure recurrence-expansion function"
```

---

### Task 4: 일정 작성/수정 화면

**Files:**
- Create: `lib/features/calendar/calendar_event_form_screen.dart`

**Interfaces:**
- Consumes: `CalendarEvent`(Task 2), `CalendarEventRepository`(Task 2)
- Produces: 이 화면 파일 상단에 선언되는 `calendarEventRepository` 최상위 인스턴스 — Task 5(캘린더 화면)가 여기서 import해 재사용한다 (기존 프로젝트 컨벤션: `transactionRepository`도 목록 화면이 아니라 `transaction_form_screen.dart`에 선언되어 있고, `transaction_list_screen.dart`가 거기서 가져다 쓴다 — 이 파일이 저장/불러오기 로직의 "본체"이기 때문). `CalendarEventFormScreen` 위젯 자체도 Task 5가 소비한다.

이 태스크를 캘린더 화면(Task 5)보다 먼저 배치한 이유: 두 화면이 서로를 참조하는 게 아니라, 캘린더 화면 쪽에서만 이 화면을 참조하는 단방향 의존이 되도록 하기 위해서다 (반대로 하면 두 파일이 서로를 import하는 순환 참조가 생긴다).

- [ ] **Step 1: 작성/수정 화면**

`lib/features/calendar/calendar_event_form_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/calendar/calendar_event_repository.dart';
import 'package:ppyu_budget/features/calendar/models/calendar_event.dart';

final calendarEventRepository = CalendarEventRepository(client: supabase);

const _weekdayLabels = [
  ('MO', '월'), ('TU', '화'), ('WE', '수'), ('TH', '목'), ('FR', '금'), ('SA', '토'), ('SU', '일'),
];

enum _Frequency { none, daily, weekly, monthly, yearly }

class CalendarEventFormScreen extends StatefulWidget {
  const CalendarEventFormScreen({
    super.key,
    required this.householdId,
    this.initialDate,
    this.existing,
  });

  final String householdId;
  final DateTime? initialDate;
  final CalendarEvent? existing;

  @override
  State<CalendarEventFormScreen> createState() => _CalendarEventFormScreenState();
}

class _CalendarEventFormScreenState extends State<CalendarEventFormScreen> {
  late final _titleController = TextEditingController(text: widget.existing?.title ?? '');
  late DateTime _date = widget.existing?.startAt ?? widget.initialDate ?? DateTime.now();
  late bool _allDay = widget.existing?.allDay ?? false;
  late TimeOfDay _startTime = TimeOfDay.fromDateTime(widget.existing?.startAt ?? DateTime.now());
  late TimeOfDay _endTime = TimeOfDay.fromDateTime(
    widget.existing?.endAt ?? DateTime.now().add(const Duration(hours: 1)),
  );
  late _Frequency _frequency = _parseFrequency(widget.existing?.recurrenceRule);
  late final Set<String> _selectedWeekdays = _parseWeekdays(widget.existing?.recurrenceRule);
  String? _error;
  bool _saving = false;

  static _Frequency _parseFrequency(String? rule) {
    if (rule == null) return _Frequency.none;
    if (rule == 'DAILY') return _Frequency.daily;
    if (rule.startsWith('WEEKLY:')) return _Frequency.weekly;
    if (rule == 'MONTHLY') return _Frequency.monthly;
    if (rule == 'YEARLY') return _Frequency.yearly;
    return _Frequency.none;
  }

  static Set<String> _parseWeekdays(String? rule) {
    if (rule == null || !rule.startsWith('WEEKLY:')) return {};
    return rule.substring(7).split(',').toSet();
  }

  String? get _recurrenceRule {
    switch (_frequency) {
      case _Frequency.none:
        return null;
      case _Frequency.daily:
        return 'DAILY';
      case _Frequency.weekly:
        return _selectedWeekdays.isEmpty ? null : 'WEEKLY:${_selectedWeekdays.join(',')}';
      case _Frequency.monthly:
        return 'MONTHLY';
      case _Frequency.yearly:
        return 'YEARLY';
    }
  }

  DateTime get _startAt => _allDay
      ? DateTime(_date.year, _date.month, _date.day)
      : DateTime(_date.year, _date.month, _date.day, _startTime.hour, _startTime.minute);

  DateTime get _endAt => _allDay
      ? DateTime(_date.year, _date.month, _date.day, 23, 59, 59)
      : DateTime(_date.year, _date.month, _date.day, _endTime.hour, _endTime.minute);

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '제목을 입력해주세요');
      return;
    }
    if (!_allDay && !_endAt.isAfter(_startAt)) {
      setState(() => _error = '종료 시각은 시작 시각보다 뒤여야 해요');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        final memberRow = await supabase
            .from('household_members')
            .select('id')
            .eq('household_id', widget.householdId)
            .eq('user_id', supabase.auth.currentUser!.id)
            .single();
        await calendarEventRepository.create(
          householdId: widget.householdId,
          title: title,
          startAt: _startAt,
          endAt: _endAt,
          allDay: _allDay,
          createdBy: memberRow['id'] as String,
          recurrenceRule: _recurrenceRule,
        );
      } else {
        await calendarEventRepository.update(
          id: existing.id,
          title: title,
          startAt: _startAt,
          endAt: _endAt,
          allDay: _allDay,
          recurrenceRule: _recurrenceRule,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '일정 저장에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final isRecurring = existing.recurrenceRule != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('일정 삭제'),
        content: Text(isRecurring ? '반복 일정 전체가 삭제돼요. 계속할까요?' : '이 일정을 삭제할까요?'),
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
      await calendarEventRepository.delete(existing.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '일정 삭제에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(context: context, initialTime: isStart ? _startTime : _endTime);
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startTime = picked;
      } else {
        _endTime = picked;
      }
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? '일정 추가' : '일정 수정'),
        actions: [
          if (existing != null)
            IconButton(icon: const Icon(Icons.delete), onPressed: _saving ? null : _delete),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: '제목'),
            ),
            ListTile(
              title: const Text('날짜'),
              subtitle: Text('${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}'),
              onTap: _pickDate,
            ),
            SwitchListTile(
              title: const Text('종일'),
              value: _allDay,
              onChanged: (v) => setState(() => _allDay = v),
            ),
            if (!_allDay) ...[
              ListTile(
                title: const Text('시작 시각'),
                subtitle: Text(_startTime.format(context)),
                onTap: () => _pickTime(true),
              ),
              ListTile(
                title: const Text('종료 시각'),
                subtitle: Text(_endTime.format(context)),
                onTap: () => _pickTime(false),
              ),
            ],
            DropdownButton<_Frequency>(
              value: _frequency,
              items: const [
                DropdownMenuItem(value: _Frequency.none, child: Text('반복 없음')),
                DropdownMenuItem(value: _Frequency.daily, child: Text('매일')),
                DropdownMenuItem(value: _Frequency.weekly, child: Text('매주')),
                DropdownMenuItem(value: _Frequency.monthly, child: Text('매월')),
                DropdownMenuItem(value: _Frequency.yearly, child: Text('매년')),
              ],
              onChanged: (v) => setState(() => _frequency = v ?? _Frequency.none),
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

- [ ] **Step 2: 수동 확인**

Run: `flutter analyze`
Expected: 새 에러 없음

- [ ] **Step 3: Commit**

```bash
git add lib/features/calendar/calendar_event_form_screen.dart
git commit -m "feat(calendar): add event create/edit screen with recurrence picker and delete confirmation"
```

---

### Task 5: 캘린더 화면 (월간 그리드)

**Files:**
- Modify: `pubspec.yaml` (table_calendar 추가)
- Create: `lib/features/calendar/calendar_screen.dart`
- Modify: `lib/features/household/home_screen.dart` (메뉴 항목 추가)

**Interfaces:**
- Consumes: `CalendarEventRepository`(Task 2), `expandOccurrences`(Task 3), `calendarEventRepository`/`CalendarEventFormScreen`(Task 4, `calendar_event_form_screen.dart`에서 import)

- [ ] **Step 1: table_calendar 추가**

Run: `flutter pub add table_calendar`

설치된 버전의 실제 API(`TableCalendar` 위젯의 필수 파라미터, `eventLoader` 콜백 시그니처, `onDaySelected` 콜백 시그니처, `calendarFormat` 등)를 pub 캐시 소스나 README에서 먼저 확인하고 Step 2를 그 시그니처에 맞게 작성한다. 아래 코드는 출발점이지 최종본이 아니다.

- [ ] **Step 2: 캘린더 화면**

`lib/features/calendar/calendar_screen.dart` (개요 — `TableCalendar` 위젯 부분은 설치된 API로 검증 후 채운다):
```dart
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:ppyu_budget/features/calendar/calendar_event_form_screen.dart' show CalendarEventFormScreen, calendarEventRepository;
import 'package:ppyu_budget/features/calendar/models/calendar_event.dart';
import 'package:ppyu_budget/features/calendar/recurrence.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  List<CalendarEvent>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final events = await calendarEventRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _events = events;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '일정을 불러오지 못했어요');
    }
  }

  // 보이는 달 앞뒤로 1개월씩 여유를 두고 발생을 계산 — 달력이 표시하는 grid가
  // 이전/다음 달의 며칠을 살짝 걸치기 때문 (다다음 주까지 넘어가는 경우 등).
  List<Occurrence> _occurrencesFor(DateTime day) {
    final events = _events;
    if (events == null) return [];
    final rangeStart = DateTime(_focusedDay.year, _focusedDay.month - 1, 1);
    final rangeEnd = DateTime(_focusedDay.year, _focusedDay.month + 2, 0, 23, 59, 59);
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = DateTime(day.year, day.month, day.day, 23, 59, 59);
    return events
        .expand((e) => expandOccurrences(e, rangeStart, rangeEnd))
        .where((o) => !o.start.isAfter(dayEnd) && !o.end.isBefore(dayStart))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final selectedDay = _selectedDay;
    return Scaffold(
      appBar: AppBar(title: const Text('캘린더')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CalendarEventFormScreen(
              householdId: widget.householdId,
              initialDate: selectedDay ?? _focusedDay,
            ),
          ));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          if (_events == null)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else ...[
            TableCalendar(
              focusedDay: _focusedDay,
              firstDay: DateTime(2000),
              lastDay: DateTime(2100),
              selectedDayPredicate: (day) => isSameDay(selectedDay, day),
              eventLoader: _occurrencesFor,
              onDaySelected: (selected, focused) {
                setState(() {
                  _selectedDay = selected;
                  _focusedDay = focused;
                });
              },
              onPageChanged: (focused) => setState(() => _focusedDay = focused),
            ),
            Expanded(
              child: selectedDay == null
                  ? const Center(child: Text('날짜를 선택하면 일정이 보여요'))
                  : Builder(builder: (context) {
                      final occurrences = _occurrencesFor(selectedDay)
                        ..sort((a, b) => a.start.compareTo(b.start));
                      if (occurrences.isEmpty) {
                        return const Center(child: Text('이 날은 일정이 없어요'));
                      }
                      return ListView.builder(
                        itemCount: occurrences.length,
                        itemBuilder: (context, i) {
                          final occ = occurrences[i];
                          // 반복 일정의 어떤 발생을 탭했는지와 무관하게, 그
                          // 발생을 만들어낸 원본 이벤트를 찾아 상세 화면에
                          // 넘긴다 — 상세 화면은 발생이 아니라 규칙 자체를
                          // 다룬다.
                          final event = _events!.firstWhere(
                            (e) => expandOccurrences(e, occ.start, occ.start).isNotEmpty ||
                                (e.startAt == occ.start),
                          );
                          return ListTile(
                            title: Text(event.title),
                            subtitle: Text(event.allDay ? '종일' : '${occ.start.hour.toString().padLeft(2, '0')}:${occ.start.minute.toString().padLeft(2, '0')}'),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => CalendarEventFormScreen(
                                  householdId: widget.householdId,
                                  existing: event,
                                ),
                              ));
                              _load();
                            },
                          );
                        },
                      );
                    }),
            ),
          ],
        ],
      ),
    );
  }
}
```

(`CalendarEventFormScreen`/`calendarEventRepository`는 위 import에서 이미 Task 4의 `calendar_event_form_screen.dart`로부터 가져왔다 — 이 시점엔 그 파일이 이미 존재하므로 별도 처리 없이 바로 컴파일된다.)

- [ ] **Step 3: 홈 화면에 메뉴 추가**

`home_screen.dart` import에 `import 'package:ppyu_budget/features/calendar/calendar_screen.dart';` 추가.

`ListTile` 목록에 추가 (거래 내역/통계 항목 근처):
```dart
            ListTile(
              title: const Text('캘린더'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CalendarScreen(householdId: householdId),
              )),
            ),
```

- [ ] **Step 4: 수동 확인**

Run: `flutter analyze`
Expected: 새 에러 없음

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/features/calendar/calendar_screen.dart lib/features/household/home_screen.dart
git commit -m "feat(calendar): add monthly calendar screen with recurring event display"
```
