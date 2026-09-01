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
