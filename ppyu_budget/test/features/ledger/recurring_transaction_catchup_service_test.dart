import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_repository.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late RecurringTransactionCatchUpService service;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    service = RecurringTransactionCatchUpService(
      recurringTransactionRepository: RecurringTransactionRepository(client: client),
      transactionRepository: TransactionRepository(client: client),
    );
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  Map<String, dynamic> _templateRow({
    String id = 'rt-1',
    String intervalRule = 'MONTHLY',
    required String startAt,
    bool autoRegister = true,
  }) =>
      {
        'id': id,
        'account_id': 'account-1',
        'category_id': 'category-1',
        'created_by': 'member-1',
        'owner_member_id': 'member-1',
        'type': 'expense',
        'amount': 50000,
        'interval_rule': intervalRule,
        'start_at': startAt,
        'auto_register': autoRegister,
        'memo': '월세',
      };

  test('creates one transaction per missing occurrence for an auto_register template', () async {
    final requests = StreamIterator<HttpRequest>(mockServer);
    // MONTHLY from 2026-07-15, checked as of 2026-08-20: July 15 and August 15
    // are both due; September 15 is not yet (it's after the cutoff).
    final future = service.run('household-1', now: DateTime.utc(2026, 8, 20));

    await requests.moveNext();
    final listRequest = requests.current;
    await listRequest.drain<void>();
    listRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_templateRow(startAt: DateTime.utc(2026, 7, 15).toIso8601String())]));
    await listRequest.response.close();

    // occurredAtsForRecurringTransaction — nothing created yet
    await requests.moveNext();
    final occurredRequest = requests.current;
    await occurredRequest.drain<void>();
    occurredRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<dynamic>[]));
    await occurredRequest.response.close();

    // MONTHLY from 2026-07-15 through 2026-08-20 (cutoff) = July and August only
    for (final expectedDate in ['2026-07-15T00:00:00.000Z', '2026-08-15T00:00:00.000Z']) {
      await requests.moveNext();
      final txnRequest = requests.current;
      final body = jsonDecode(await utf8.decodeStream(txnRequest)) as Map<String, dynamic>;
      expect(body['occurred_at'], expectedDate);
      expect(body['recurring_transaction_id'], 'rt-1');
      txnRequest.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(jsonEncode([
          {
            'id': 'txn-$expectedDate', 'account_id': 'account-1', 'category_id': 'category-1',
            'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
            'occurred_at': expectedDate, 'source': 'recurring_auto', 'memo': '월세', 'merchant': null,
          },
        ]));
      await txnRequest.response.close();
    }

    expect(await future, 2);
    await requests.cancel();
  });

  test('skips a template entirely when auto_register is false', () async {
    final future = service.run('household-1', now: DateTime.utc(2026, 9, 20));

    final listRequest = await mockServer.first;
    await listRequest.drain<void>();
    listRequest.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([_templateRow(startAt: DateTime.utc(2026, 7, 15).toIso8601String(), autoRegister: false)]));
    await listRequest.response.close();

    // No further requests should follow. `mockServer.first` closes the
    // server's listening socket after taking that one request, so a
    // regression that fires a second request gets connection-refused and
    // `run()` throws a SocketException — the test fails on that, not on a
    // hang.
    expect(await future, 0);
  });

  test('ignores a unique_violation from a concurrent duplicate and continues', () async {
    var txnAttempt = 0;

    mockServer.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/recurring_transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([_templateRow(intervalRule: 'DAILY', startAt: DateTime.utc(2026, 9, 1).toIso8601String())]));
        await request.response.close();
      } else if (request.method == 'GET' && request.uri.path.endsWith('/transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<dynamic>[]));
        await request.response.close();
      } else if (request.method == 'POST' && request.uri.path.endsWith('/transactions')) {
        txnAttempt++;
        await request.drain<void>();
        if (txnAttempt == 1) {
          // simulate a concurrent session having already created this exact occurrence
          request.response
            ..statusCode = HttpStatus.conflict
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'code': '23505', 'message': 'duplicate key value violates unique constraint'}));
        } else {
          request.response
            ..statusCode = HttpStatus.created
            ..headers.contentType = ContentType.json
            ..write(jsonEncode([
              {
                'id': 'txn-$txnAttempt', 'account_id': 'account-1', 'category_id': 'category-1',
                'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
                'occurred_at': DateTime.now().toUtc().toIso8601String(), 'source': 'recurring_auto',
                'memo': null, 'merchant': null,
              },
            ]));
        }
        await request.response.close();
      }
    });

    final count = await service.run('household-1', now: DateTime.utc(2026, 9, 2));

    // DAILY from Sep 1 through Sep 2 = 2 occurrences; the first attempt hits
    // the simulated duplicate and is ignored, the second succeeds.
    expect(count, 1);
    expect(txnAttempt, 2);
  });

  test('propagates a non-23505 PostgrestException instead of swallowing it', () async {
    mockServer.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/recurring_transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([_templateRow(intervalRule: 'DAILY', startAt: DateTime.utc(2026, 9, 1).toIso8601String())]));
        await request.response.close();
      } else if (request.method == 'GET' && request.uri.path.endsWith('/transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<dynamic>[]));
        await request.response.close();
      } else if (request.method == 'POST' && request.uri.path.endsWith('/transactions')) {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'code': '42501', 'message': 'permission denied'}));
        await request.response.close();
      }
    });

    await expectLater(
      service.run('household-1', now: DateTime.utc(2026, 9, 1)),
      throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '42501')),
    );
  });
}
