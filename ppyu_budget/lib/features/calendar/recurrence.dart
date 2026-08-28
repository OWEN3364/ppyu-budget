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
    // An empty day set ('WEEKLY:' or only invalid codes) is a malformed rule —
    // fall back to a single occurrence like every other malformed case below,
    // instead of silently dropping the event.
    if (days.isEmpty) {
      return inRange(event.startAt) ? [occ(event.startAt)] : [];
    }
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
