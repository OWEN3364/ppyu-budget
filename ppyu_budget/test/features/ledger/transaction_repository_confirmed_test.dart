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

  // confirmed/recurring_transaction_id are real response columns as of
  // migration 0011, included here for a realistic mock even though
  // LedgerTransaction.fromJson doesn't parse them (nothing in this plan's
  // UI needs them on the model — see Task 4's note).
  Map<String, dynamic> _txnRow({bool confirmed = true, String? recurringTransactionId}) => {
        'id': 'txn-1',
        'account_id': 'account-1',
        'category_id': 'category-1',
        'member_id': 'member-1',
        'type': 'expense',
        'amount': 1000,
        'occurred_at': '2026-09-01T00:00:00.000Z',
        'source': 'recurring_auto',
        'memo': null,
        'merchant': null,
        'confirmed': confirmed,
        'recurring_transaction_id': recurringTransactionId,
      };

  test('list adds a confirmed filter only when confirmed is non-null', () async {
    final future = repo.list('household-1', confirmed: true);
    final request = await mockServer.first;
    expect(request.uri.queryParameters['confirmed'], 'eq.true');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_txnRow()]));
    await request.response.close();
    await future;
  });

  test('list omits the confirmed filter when confirmed is null', () async {
    final future = repo.list('household-1');
    final request = await mockServer.first;
    expect(request.uri.queryParameters.containsKey('confirmed'), isFalse);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_txnRow()]));
    await request.response.close();
    await future;
  });

  test('create sends confirmed and recurring_transaction_id', () async {
    final future = repo.create(
      householdId: 'household-1',
      accountId: 'account-1',
      categoryId: 'category-1',
      memberId: 'member-1',
      type: 'expense',
      amount: 1000,
      source: 'recurring_auto',
      recurringTransactionId: 'rt-1',
      confirmed: false,
    );
    final request = await mockServer.first;
    final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    expect(body['confirmed'], false);
    expect(body['recurring_transaction_id'], 'rt-1');
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_txnRow(confirmed: false, recurringTransactionId: 'rt-1')]));
    await request.response.close();
    await future;
  });

  test('confirm sets confirmed to true by id', () async {
    final future = repo.confirm('txn-1');
    final request = await mockServer.first;
    expect(request.method, 'PATCH');
    expect(request.uri.queryParameters['id'], 'eq.txn-1');
    expect(jsonDecode(await utf8.decodeStream(request)), {'confirmed': true});
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    await future;
  });

  test('occurredAtsForRecurringTransaction returns the set of existing occurred_at values', () async {
    final future = repo.occurredAtsForRecurringTransaction('rt-1');
    final request = await mockServer.first;
    expect(request.uri.queryParameters['recurring_transaction_id'], 'eq.rt-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'occurred_at': '2026-09-01T00:00:00.000Z'},
        {'occurred_at': '2026-10-01T00:00:00.000Z'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, {DateTime.parse('2026-09-01T00:00:00.000Z'), DateTime.parse('2026-10-01T00:00:00.000Z')});
  });
}
