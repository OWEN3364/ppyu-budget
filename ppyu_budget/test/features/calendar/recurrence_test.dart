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
    // Jan 31 recurrence over Feb-Apr range:
    // - Feb: candidate rolls to Mar 3 (skip-guard: month != 2, skip)
    // - Mar: candidate is Mar 31 (skip-guard: month == 3, add occurrence)
    // - Apr: candidate rolls to May 1 (break on isAfter rangeEnd)
    // Expected: exactly 1 occurrence on Mar 31 (Feb skipped by guard, Apr has no 31st)
    final event = _event(start: DateTime(2026, 1, 31, 10), end: DateTime(2026, 1, 31, 11), rule: 'MONTHLY');
    final result = expandOccurrences(event, DateTime(2026, 2, 1), DateTime(2026, 4, 30, 23, 59, 59));
    expect(result, hasLength(1));
    expect(result.first.start, DateTime(2026, 3, 31, 10));
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
