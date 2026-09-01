import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_schedule.dart';

void main() {
  test('DAILY advances by exactly one day', () {
    final next = advanceOccurrence('DAILY', DateTime(2026, 9, 5, 10));
    expect(next, DateTime(2026, 9, 6, 10));
  });

  test('WEEKLY:MO,WE,FR advances to the next matching weekday', () {
    // 2026-09-07 is a Monday
    final next = advanceOccurrence('WEEKLY:MO,WE,FR', DateTime(2026, 9, 7, 8));
    expect(next.weekday, DateTime.wednesday);
    expect(next, DateTime(2026, 9, 9, 8));
  });

  test('WEEKLY with a single day wraps to the same weekday next week', () {
    final next = advanceOccurrence('WEEKLY:MO', DateTime(2026, 9, 7, 8)); // a Monday
    expect(next, DateTime(2026, 9, 14, 8));
  });

  test('MONTHLY advances to the same day next month', () {
    final next = advanceOccurrence('MONTHLY', DateTime(2026, 9, 15, 10));
    expect(next, DateTime(2026, 10, 15, 10));
  });

  test('MONTHLY rolls forward (does not skip) when the day does not exist in the next month', () {
    // Jan 31 -> Feb has no 31st -> rolls into March, unlike the calendar's skip behavior
    final next = advanceOccurrence('MONTHLY', DateTime(2026, 1, 31, 10));
    expect(next, DateTime(2026, 3, 3, 10));
  });

  test('YEARLY advances to the same month/day next year', () {
    final next = advanceOccurrence('YEARLY', DateTime(2026, 9, 15, 10));
    expect(next, DateTime(2027, 9, 15, 10));
  });

  test('an unrecognized rule degrades to a daily step instead of looping forever', () {
    final next = advanceOccurrence('GARBAGE', DateTime(2026, 9, 5, 10));
    expect(next, DateTime(2026, 9, 6, 10));
  });

  test('an empty WEEKLY rule degrades to a daily step instead of looping forever', () {
    final next = advanceOccurrence('WEEKLY:', DateTime(2026, 9, 5, 10));
    expect(next, DateTime(2026, 9, 6, 10));
  });

  test('maxCatchUpOccurrences is a sane positive cap', () {
    expect(maxCatchUpOccurrences, 60);
  });
}
