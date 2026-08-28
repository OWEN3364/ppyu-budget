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

  // PostgREST returns timestamptz with a Z/+00:00 suffix, so DateTime.parse
  // yields isUtc == true. Every consumer downstream (recurrence expansion,
  // the day list, the form's time prefill) reasons in local wall-clock time,
  // so convert once here at the boundary rather than at each call site.
  // The write path's .toUtc() in CalendarEventRepository stays correct as-is.
  factory CalendarEvent.fromJson(Map<String, dynamic> json) => CalendarEvent(
        id: json['id'] as String,
        title: json['title'] as String,
        startAt: DateTime.parse(json['start_at'] as String).toLocal(),
        endAt: DateTime.parse(json['end_at'] as String).toLocal(),
        allDay: json['all_day'] as bool,
        createdBy: json['created_by'] as String,
        recurrenceRule: json['recurrence_rule'] as String?,
      );
}
