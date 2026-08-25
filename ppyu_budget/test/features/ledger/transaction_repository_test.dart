import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late TransactionRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = TransactionRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s transactions', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/transactions'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't1',
          'account_id': 'a1',
          'category_id': 'c1',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 12000,
          'occurred_at': '2026-08-25T12:00:00Z',
          'memo': '점심',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.amount, 12000);
    expect(result.first.memo, '점심');
  });

  test('create posts a new transaction', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'a1',
      categoryId: 'c1',
      memberId: 'm1',
      type: 'expense',
      amount: 5000,
      memo: '커피',
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'account_id': 'a1',
      'category_id': 'c1',
      'member_id': 'm1',
      'type': 'expense',
      'amount': 5000,
      'memo': '커피',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't2',
          'account_id': 'a1',
          'category_id': 'c1',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 5000,
          'occurred_at': '2026-08-25T13:00:00Z',
          'memo': '커피',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.amount, 5000);
  });

  test('delete removes a transaction by id', () async {
    final future = repo.delete('t1');

    final request = await mockServer.first;
    expect(request.method, 'DELETE');
    expect(request.uri.path, endsWith('/transactions'));
    expect(request.uri.queryParameters['id'], 'eq.t1');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });
}
