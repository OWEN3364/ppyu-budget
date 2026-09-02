import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';

const maxCatchUpOccurrences = 60;

const _weekdayCodes = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

/// Returns the next occurrence after [from] for [intervalRule]. Always
/// strictly after `from` (never equal), so repeated calls from a starting
/// point walk forward without repeating.
DateTime advanceOccurrence(String intervalRule, DateTime from) {
  if (intervalRule == 'DAILY') {
    return from.add(const Duration(days: 1));
  }

  if (intervalRule.startsWith('WEEKLY:')) {
    final days = intervalRule.substring(7).split(',').map((c) => _weekdayCodes[c]).whereType<int>().toSet();
    var next = from.add(const Duration(days: 1));
    if (days.isEmpty) return next; // malformed rule: degrade to daily rather than looping forever
    while (!days.contains(next.weekday)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }

  if (intervalRule == 'MONTHLY') {
    // Unlike the calendar's expandOccurrences (which SKIPS a month that
    // doesn't have the day-of-month, since it's just deciding what to
    // display), this rolls forward to the nearest valid date instead — see
    // the plan's Global Constraints for why: silently skipping a real
    // payment for a whole month is a worse surprise than charging it a few
    // days into the next month. DateTime's constructor does this rollover
    // on its own (e.g. day=31 in a 30-day month becomes the 1st of the
    // month after), so no extra guard is needed here.
    //
    // The rollover is NOT self-correcting on later months either: each step
    // is computed from the PREVIOUS computed occurrence, not from the
    // original anchor day, so Jan 31 -> Mar 3 -> Apr 3 -> May 3 -> ...
    // permanently drifts to the 3rd rather than ever returning to the 31st.
    // Deliberate: a stable (if drifted) date is easier to reason about than
    // a date that keeps snapping back and forth month to month.
    return DateTime(from.year, from.month + 1, from.day, from.hour, from.minute);
  }

  if (intervalRule == 'YEARLY') {
    return DateTime(from.year + 1, from.month, from.day, from.hour, from.minute);
  }

  // ponytail: unrecognized rule degrades to a daily step rather than looping
  // forever — interval_rule is only ever written by this app's own form
  // (always one of the 4 known shapes), so this path is unreachable in
  // normal use; it exists only so a caller looping on this function always
  // terminates.
  return from.add(const Duration(days: 1));
}

/// Every occurrence [template] should have between its `startAt` and [now]
/// (inclusive), excluding dates already covered by [existingOccurredAt].
/// Compared by instant (`.toUtc()`), never by local calendar fields — an
/// entry in [existingOccurredAt] may or may not already be
/// `.toLocal()`-converted depending on which caller read it, and comparing
/// raw DateTime values could silently miss a real match.
///
/// ponytail: capped at [maxCatchUpOccurrences] occurrences RETURNED (i.e.
/// actually missing) per call — the same cap that bounds silent
/// auto-creation also bounds how far back the todo screen walks per
/// template per load. Corrected during final review: the cap used to count
/// occurrences EXAMINED, which silently became a per-template LIFETIME
/// ceiling once `start_at` stopped being an advancing pointer — the walk
/// always restarts at the fixed anchor, so after 60 dates had been examined
/// (matched or not) the template could never produce anything again.
/// Walking a long already-matched prefix is cheap pure in-memory iteration
/// — no I/O — so bounding created work, not examined work, is the right
/// guarantee. Raise the cap (or split into a separate, todo-specific
/// constant) only if a real household's overdue backlog ever hits it.
List<DateTime> missingOccurrences(
  RecurringTransaction template, {
  required DateTime now,
  required Set<DateTime> existingOccurredAt,
}) {
  final existingUtc = existingOccurredAt.map((d) => d.toUtc()).toSet();
  final missing = <DateTime>[];
  var cursor = template.startAt;
  while (!cursor.isAfter(now) && missing.length < maxCatchUpOccurrences) {
    if (!existingUtc.contains(cursor.toUtc())) {
      missing.add(cursor);
    }
    cursor = advanceOccurrence(template.intervalRule, cursor);
  }
  return missing;
}
