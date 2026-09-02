import 'dart:async';
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
      'confirmed': true,
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
      'confirmed': true,
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
    final iterator = StreamIterator(mockServer);
    final future = repo.update(
      id: 't1',
      accountId: 'a2',
      categoryId: 'c2',
      type: 'expense',
      amount: 7000,
      memo: '수정됨',
      merchant: '스타벅스 강남점',
    );

    await iterator.moveNext();
    final patchRequest = iterator.current;
    expect(patchRequest.method, 'PATCH');
    expect(patchRequest.uri.queryParameters['id'], 'eq.t1');
    final bodyStr = await utf8.decodeStream(patchRequest);
    expect(jsonDecode(bodyStr), {
      'account_id': 'a2',
      'category_id': 'c2',
      'type': 'expense',
      'amount': 7000,
      'memo': '수정됨',
      'merchant': '스타벅스 강남점',
    });
    patchRequest.response
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
    await patchRequest.response.close();

    await iterator.moveNext();
    final deleteTagsRequest = iterator.current;
    expect(deleteTagsRequest.method, 'DELETE');
    expect(deleteTagsRequest.uri.path, endsWith('/transaction_tags'));
    // the one silently-destructive filter in the phase: a wrong eq would wipe
    // every transaction_tags row in the household without surfacing an error
    expect(deleteTagsRequest.uri.queryParameters['transaction_id'], 'eq.t1');
    deleteTagsRequest.response.statusCode = HttpStatus.noContent;
    await deleteTagsRequest.response.close();

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

  test('create saves the transaction then replaces its tags', () async {
    final iterator = StreamIterator(mockServer);
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      memberId: 'member-1',
      type: 'expense',
      amount: 5000,
      tagIds: ['tag-1', 'tag-2'],
    );

    await iterator.moveNext();
    final insertRequest = iterator.current;
    expect(insertRequest.method, 'POST');
    expect(insertRequest.uri.path, endsWith('/transactions'));
    insertRequest.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'txn-1',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'member_id': 'member-1',
          'type': 'expense',
          'amount': 5000,
          'occurred_at': '2026-08-26T00:00:00Z',
          'source': 'manual',
          'memo': null,
          'merchant': null,
        },
      ]));
    await insertRequest.response.close();

    await iterator.moveNext();
    final deleteTagsRequest = iterator.current;
    expect(deleteTagsRequest.method, 'DELETE');
    expect(deleteTagsRequest.uri.path, endsWith('/transaction_tags'));
    expect(deleteTagsRequest.uri.queryParameters['transaction_id'], 'eq.txn-1');
    deleteTagsRequest.response.statusCode = HttpStatus.noContent;
    await deleteTagsRequest.response.close();

    await iterator.moveNext();
    final insertTagsRequest = iterator.current;
    expect(insertTagsRequest.method, 'POST');
    expect(insertTagsRequest.uri.path, endsWith('/transaction_tags'));
    final bodyStr = await utf8.decodeStream(insertTagsRequest);
    expect(jsonDecode(bodyStr), [
      {'transaction_id': 'txn-1', 'tag_id': 'tag-1'},
      {'transaction_id': 'txn-1', 'tag_id': 'tag-2'},
    ]);
    insertTagsRequest.response.statusCode = HttpStatus.created;
    await insertTagsRequest.response.close();

    final result = await future;
    expect(result.id, 'txn-1');
    expect(result.tagIds, ['tag-1', 'tag-2']);
  });

  test('create sends occurred_at converted to UTC when provided', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      memberId: 'member-1',
      type: 'expense',
      amount: 50000,
      source: 'recurring_auto',
      occurredAt: DateTime.parse('2026-09-06T06:00:00+09:00'),
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    final body = jsonDecode(bodyStr) as Map<String, dynamic>;
    expect(body['occurred_at'], '2026-09-05T21:00:00.000Z');
    expect(body['source'], 'recurring_auto');
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'txn-x',
          'account_id': 'account-1',
          'category_id': 'category-1',
          'member_id': 'member-1',
          'type': 'expense',
          'amount': 50000,
          'occurred_at': '2026-09-05T21:00:00.000Z',
          'source': 'recurring_auto',
          'memo': null,
          'merchant': null,
        },
      ]));
    await request.response.close();

    await future;
  });
}
