import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';
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

  group('missingOccurrences', () {
    test('returns every date from startAt through now when nothing exists yet', () {
      final template = _template(startAt: DateTime(2026, 9, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(template, now: DateTime(2026, 9, 4), existingOccurredAt: {});
      expect(missing, [
        DateTime(2026, 9, 1),
        DateTime(2026, 9, 2),
        DateTime(2026, 9, 3),
        DateTime(2026, 9, 4),
      ]);
    });

    test('excludes a date that already has a matching transaction', () {
      final template = _template(startAt: DateTime(2026, 9, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(
        template,
        now: DateTime(2026, 9, 3),
        existingOccurredAt: {DateTime(2026, 9, 2)},
      );
      expect(missing, [DateTime(2026, 9, 1), DateTime(2026, 9, 3)]);
    });

    test('matches an existing date by instant, not by local representation', () {
      // existingOccurredAt holds a UTC-flagged DateTime for the same instant
      // as the second expected occurrence — must still be recognized as a match.
      final template = _template(startAt: DateTime(2026, 9, 1), intervalRule: 'DAILY');
      final secondOccurrenceUtc = DateTime(2026, 9, 2).toUtc();
      final missing = missingOccurrences(
        template,
        now: DateTime(2026, 9, 2),
        existingOccurredAt: {secondOccurrenceUtc},
      );
      expect(missing, [DateTime(2026, 9, 1)]);
    });

    test('returns nothing when startAt is after now', () {
      final template = _template(startAt: DateTime(2026, 10, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(template, now: DateTime(2026, 9, 1), existingOccurredAt: {});
      expect(missing, isEmpty);
    });

    test('stops examining after maxCatchUpOccurrences even if all are missing', () {
      final template = _template(startAt: DateTime(2026, 1, 1), intervalRule: 'DAILY');
      final missing = missingOccurrences(template, now: DateTime(2026, 12, 31), existingOccurredAt: {});
      expect(missing, hasLength(maxCatchUpOccurrences));
      expect(missing.last, DateTime(2026, 1, 1).add(Duration(days: maxCatchUpOccurrences - 1)));
    });

    test('finds occurrences beyond the cap-worth of already-matched history (regression: cap must bound MISSING occurrences, not examined ones)', () {
      // A DAILY template with 100 days of history, days 0-99 ALL already
      // matched (real transactions exist) — under the old "examined" cap
      // semantics, the walk would exhaust its 60-count budget entirely inside
      // this matched prefix and never reach the genuinely missing days 100+.
      final startAt = DateTime(2026, 1, 1);
      final template = _template(startAt: startAt, intervalRule: 'DAILY');
      final matchedPrefix = List.generate(100, (i) => startAt.add(Duration(days: i))).toSet();
      final now = startAt.add(const Duration(days: 150));

      final missing = missingOccurrences(template, now: now, existingOccurredAt: matchedPrefix);

      // Days 100 through 150 inclusive = 51 genuinely missing days — well
      // under the cap, so all of them must be found.
      expect(missing, hasLength(51));
      expect(missing.first, startAt.add(const Duration(days: 100)));
      expect(missing.last, startAt.add(const Duration(days: 150)));
    });
  });
}

RecurringTransaction _template({
  required DateTime startAt,
  String intervalRule = 'DAILY',
}) =>
    RecurringTransaction(
      id: 'rt-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      ownerMemberId: 'member-1',
      type: 'expense',
      amount: 1000,
      intervalRule: intervalRule,
      startAt: startAt,
      autoRegister: false,
    );
