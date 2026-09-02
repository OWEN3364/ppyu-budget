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

  Map<String, dynamic> _row({
    String id = 'rt-1',
    String ownerMemberId = 'member-1',
    String startAt = '2026-09-06T21:00:00.000Z',
    bool autoRegister = false,
  }) => {
        'id': id,
        'account_id': 'account-1',
        'category_id': 'category-1',
        'created_by': 'member-1',
        'owner_member_id': ownerMemberId,
        'type': 'expense',
        'amount': 50000,
        'interval_rule': 'MONTHLY',
        'start_at': startAt,
        'auto_register': autoRegister,
        'memo': null,
      };

  test('list parses start_at as local time and auto_register/owner_member_id, not UTC', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/recurring_transactions'));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_row(ownerMemberId: 'member-2', autoRegister: true)]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.startAt.isUtc, isFalse);
    expect(result.first.ownerMemberId, 'member-2');
    expect(result.first.autoRegister, isTrue);
  });

  test('create sends start_at converted to UTC, owner_member_id, and auto_register', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      ownerMemberId: 'member-2',
      type: 'expense',
      amount: 50000,
      intervalRule: 'MONTHLY',
      startAt: DateTime.parse('2026-09-05T21:00:00.000Z').toLocal(),
      autoRegister: true,
    );

    final request = await mockServer.first;
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    expect(body['start_at'], '2026-09-05T21:00:00.000Z');
    expect(body['owner_member_id'], 'member-2');
    expect(body['auto_register'], true);
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_row(ownerMemberId: 'member-2', startAt: '2026-09-05T21:00:00.000Z', autoRegister: true)]));
    await request.response.close();

    await future;
  });

  test('update sends every field including start_at, unconditionally', () async {
    final future = repo.update(
      id: 'rt-1',
      accountId: 'account-2',
      categoryId: 'category-2',
      ownerMemberId: 'member-2',
      type: 'income',
      amount: 100000,
      intervalRule: 'WEEKLY',
      startAt: DateTime.parse('2026-11-05T21:00:00.000Z').toLocal(),
      autoRegister: true,
      memo: 'Updated memo',
    );

    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.rt-1');
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    expect(body, {
      'account_id': 'account-2',
      'category_id': 'category-2',
      'owner_member_id': 'member-2',
      'type': 'income',
      'amount': 100000,
      'interval_rule': 'WEEKLY',
      'start_at': '2026-11-05T21:00:00.000Z',
      'auto_register': true,
      'memo': 'Updated memo',
    });
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_row(ownerMemberId: 'member-2', startAt: '2026-11-05T21:00:00.000Z', autoRegister: true)]));
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
