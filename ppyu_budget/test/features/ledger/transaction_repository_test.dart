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
          'source': 'manual',
          'merchant': null,
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
      'merchant': null,
      'source': 'manual',
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
          'source': 'manual',
          'merchant': null,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.amount, 5000);
  });

  test('create sends merchant and source when provided', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'a1',
      categoryId: 'c1',
      memberId: 'm1',
      type: 'expense',
      amount: 5000,
      merchant: '스타벅스',
      source: 'notification_auto',
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
      'memo': null,
      'merchant': '스타벅스',
      'source': 'notification_auto',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't3',
          'account_id': 'a1',
          'category_id': 'c1',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 5000,
          'occurred_at': '2026-08-26T09:00:00+00:00',
          'source': 'notification_auto',
          'memo': null,
          'merchant': '스타벅스',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.merchant, '스타벅스');
    expect(result.source, 'notification_auto');
  });

  test('update patches an existing transaction', () async {
    final future = repo.update(
      id: 't1',
      accountId: 'a2',
      categoryId: 'c2',
      type: 'expense',
      amount: 7000,
      memo: '수정됨',
      merchant: '스타벅스 강남점',
    );

    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.t1');
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'account_id': 'a2',
      'category_id': 'c2',
      'type': 'expense',
      'amount': 7000,
      'memo': '수정됨',
      'merchant': '스타벅스 강남점',
    });
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 't1',
          'account_id': 'a2',
          'category_id': 'c2',
          'member_id': 'm1',
          'type': 'expense',
          'amount': 7000,
          'occurred_at': '2026-08-26T09:00:00+00:00',
          'source': 'manual',
          'memo': '수정됨',
          'merchant': '스타벅스 강남점',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.amount, 7000);
    expect(result.merchant, '스타벅스 강남점');
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
