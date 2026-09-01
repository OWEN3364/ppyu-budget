import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late RecurringTransactionRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = RecurringTransactionRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list parses next_run_at as local time, not UTC', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/recurring_transactions'));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'rt-1',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'created_by': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'interval_rule': 'MONTHLY',
          'next_run_at': '2026-09-06T21:00:00.000Z',
          'memo': null,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.nextRunAt.isUtc, isFalse);
  });

  test('create sends next_run_at converted to UTC', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      type: 'expense',
      amount: 50000,
      intervalRule: 'MONTHLY',
      nextRunAt: DateTime.parse('2026-09-06T06:00:00+09:00'),
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    final body = jsonDecode(bodyStr) as Map<String, dynamic>;
    expect(body['next_run_at'], '2026-09-05T21:00:00.000Z');
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'rt-2',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'created_by': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'interval_rule': 'MONTHLY',
          'next_run_at': '2026-09-05T21:00:00.000Z',
          'memo': null,
        },
      ]));
    await request.response.close();

    await future;
  });

  test('advanceNextRunAt only sends next_run_at, converted to UTC', () async {
    final future = repo.advanceNextRunAt('rt-1', DateTime.parse('2026-10-06T06:00:00+09:00'));

    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.rt-1');
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'next_run_at': '2026-10-05T21:00:00.000Z'});
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });

  test('delete removes a template by id', () async {
    final future = repo.delete('rt-1');

    final request = await mockServer.first;
    expect(request.method, 'DELETE');
    expect(request.uri.queryParameters['id'], 'eq.rt-1');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });
}
