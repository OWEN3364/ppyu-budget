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
