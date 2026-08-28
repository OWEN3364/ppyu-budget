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
