import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/budget_repository.dart';

void main() {
  late HttpServer mockServer;
  // HttpServer is a single-subscription Stream, so a test that awaits
  // `mockRequests.first` more than once (select, then insert/update) needs a
  // broadcast view: each `.first` re-subscribes, which a plain
  // single-subscription stream forbids after the first subscription ends.
  late Stream<HttpRequest> mockRequests;
  late SupabaseClient client;
  late BudgetRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    mockRequests = mockServer.asBroadcastStream();
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = BudgetRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s budgets for a month', () async {
    final future = repo.list('household-1', DateTime.utc(2026, 9));

    final request = await mockRequests.first;
    expect(request.uri.path, endsWith('/budgets'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    expect(request.uri.queryParameters['month'], 'eq.2026-09-01');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'b1', 'category_id': null, 'month': '2026-09-01', 'amount': 1000000},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.amount, 1000000);
    expect(result.first.categoryId, isNull);
  });

  test('upsert inserts a new budget when none exists yet for the month/category',
      () async {
    final future = repo.upsert(
      householdId: 'household-1',
      categoryId: 'c1',
      month: DateTime.utc(2026, 9),
      amount: 300000,
    );

    final selectRequest = await mockRequests.first;
    expect(selectRequest.method, 'GET');
    expect(selectRequest.uri.path, endsWith('/budgets'));
    expect(selectRequest.uri.queryParameters['category_id'], 'eq.c1');
    selectRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<Object?>[]));
    await selectRequest.response.close();

    final insertRequest = await mockRequests.first;
    expect(insertRequest.method, 'POST');
    final bodyStr = await utf8.decodeStream(insertRequest);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'category_id': 'c1',
      'month': '2026-09-01',
      'amount': 300000,
    });
    insertRequest.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'b2', 'category_id': 'c1', 'month': '2026-09-01', 'amount': 300000},
      ]));
    await insertRequest.response.close();

    final result = await future;
    expect(result.amount, 300000);
  });

  test('upsert updates the existing budget when one already exists', () async {
    final future = repo.upsert(
      householdId: 'household-1',
      categoryId: null,
      month: DateTime.utc(2026, 9),
      amount: 1200000,
    );

    final selectRequest = await mockRequests.first;
    expect(selectRequest.method, 'GET');
    expect(selectRequest.uri.queryParameters['category_id'], 'is.null');
    selectRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'b1'},
      ]));
    await selectRequest.response.close();

    final updateRequest = await mockRequests.first;
    expect(updateRequest.method, 'PATCH');
    expect(updateRequest.uri.queryParameters['id'], 'eq.b1');
    final bodyStr = await utf8.decodeStream(updateRequest);
    expect(jsonDecode(bodyStr), {'amount': 1200000});
    updateRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'b1', 'category_id': null, 'month': '2026-09-01', 'amount': 1200000},
      ]));
    await updateRequest.response.close();

    final result = await future;
    expect(result.amount, 1200000);
    expect(result.categoryId, isNull);
  });
}
