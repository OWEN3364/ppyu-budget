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

  test('creates one transaction per overdue occurrence and advances next_run_at incrementally', () async {
    final requests = StreamIterator<HttpRequest>(mockServer);
    final future = service.run('household-1', now: DateTime.utc(2026, 8, 20));

    // 1: list recurring_transactions — one MONTHLY template last run 2026-07-15
    await requests.moveNext();
    final listRequest = requests.current;
    await listRequest.drain<void>();
    listRequest.response
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
          'next_run_at': DateTime.utc(2026, 7, 15).toIso8601String(),
          'memo': '월세',
        },
      ]));
    await listRequest.response.close();

    // 2: first overdue occurrence — creates the July transaction
    await requests.moveNext();
    final txn1Request = requests.current;
    expect(txn1Request.method, 'POST');
    expect(txn1Request.uri.path, endsWith('/transactions'));
    final txn1Body = jsonDecode(await utf8.decodeStream(txn1Request)) as Map<String, dynamic>;
    expect(txn1Body['occurred_at'], '2026-07-15T00:00:00.000Z');
    expect(txn1Body['source'], 'recurring_auto');
    txn1Request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'txn-1', 'account_id': 'account-1', 'category_id': 'category-1',
          'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
          'occurred_at': '2026-07-15T00:00:00.000Z', 'source': 'recurring_auto',
          'memo': '월세', 'merchant': null,
        },
      ]));
    await txn1Request.response.close();

    // 3: advance next_run_at to August right after the July occurrence succeeds
    await requests.moveNext();
    final patch1Request = requests.current;
    expect(patch1Request.method, 'PATCH');
    final patch1Body = jsonDecode(await utf8.decodeStream(patch1Request)) as Map<String, dynamic>;
    expect(patch1Body['next_run_at'], '2026-08-15T00:00:00.000Z');
    patch1Request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'rt-1'},
      ]));
    await patch1Request.response.close();

    // 4: second overdue occurrence — creates the August transaction
    await requests.moveNext();
    final txn2Request = requests.current;
    expect(txn2Request.method, 'POST');
    final txn2Body = jsonDecode(await utf8.decodeStream(txn2Request)) as Map<String, dynamic>;
    expect(txn2Body['occurred_at'], '2026-08-15T00:00:00.000Z');
    txn2Request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 'txn-2', 'account_id': 'account-1', 'category_id': 'category-1',
          'member_id': 'member-1', 'type': 'expense', 'amount': 50000,
          'occurred_at': '2026-08-15T00:00:00.000Z', 'source': 'recurring_auto',
          'memo': '월세', 'merchant': null,
        },
      ]));
    await txn2Request.response.close();

    // 5: advance next_run_at to September (now past `now`, so the loop stops there)
    await requests.moveNext();
    final patch2Request = requests.current;
    expect(patch2Request.method, 'PATCH');
    final patch2Body = jsonDecode(await utf8.decodeStream(patch2Request)) as Map<String, dynamic>;
    expect(patch2Body['next_run_at'], '2026-09-15T00:00:00.000Z');
    patch2Request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'rt-1'},
      ]));
    await patch2Request.response.close();

    expect(await future, 2);
    await requests.cancel();
  });

  test('a template that is not yet due creates nothing', () async {
    final requests = StreamIterator<HttpRequest>(mockServer);
    final future = service.run('household-1', now: DateTime.utc(2026, 8, 20));

    await requests.moveNext();
    final listRequest = requests.current;
    await listRequest.drain<void>();
    listRequest.response
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
          'next_run_at': DateTime.utc(2026, 10, 1).toIso8601String(),
          'memo': null,
        },
      ]));
    await listRequest.response.close();

    expect(await future, 0);
    await requests.cancel();
  });

  test('respects maxCatchUpOccurrences and leaves the remainder for next time', () async {
    // A DAILY template overdue since 2026-01-01, checked on 2026-12-31, is
    // hundreds of days behind — far more than the 60-occurrence cap. This
    // needs ~121 request/response round trips (1 list + 60×(create+advance)),
    // too many to script individually like the tests above — a generic
    // path-based auto-responder counts them instead.
    var postCount = 0;
    var patchCount = 0;
    DateTime? lastPatchedNextRunAt;

    mockServer.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/recurring_transactions')) {
        await request.drain<void>();
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
              'amount': 1000,
              'interval_rule': 'DAILY',
              'next_run_at': DateTime.utc(2026, 1, 1).toIso8601String(),
              'memo': null,
            },
          ]));
        await request.response.close();
      } else if (request.method == 'POST' && request.uri.path.endsWith('/transactions')) {
        postCount++;
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.created
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([
            {
              'id': 'txn-$postCount', 'account_id': 'account-1', 'category_id': 'category-1',
              'member_id': 'member-1', 'type': 'expense', 'amount': 1000,
              'occurred_at': DateTime.now().toUtc().toIso8601String(), 'source': 'recurring_auto',
              'memo': null, 'merchant': null,
            },
          ]));
        await request.response.close();
      } else if (request.method == 'PATCH' && request.uri.path.endsWith('/recurring_transactions')) {
        patchCount++;
        final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
        lastPatchedNextRunAt = DateTime.parse(body['next_run_at'] as String);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([
            {'id': 'rt-1'},
          ]));
        await request.response.close();
      }
    });

    final count = await service.run('household-1', now: DateTime.utc(2026, 12, 31));

    expect(count, 60);
    expect(postCount, 60);
    expect(patchCount, 60);
    // Jan 1 + 59 days (the 60th created occurrence) = Mar 1; one more advance
    // past it (not created — the cap already tripped) lands on Mar 2, which
    // is what gets persisted as the template's new next_run_at.
    expect(lastPatchedNextRunAt, DateTime.utc(2026, 3, 2));
  });

  test('stops a template early when a concurrent session already advanced next_run_at (CAS failure)', () async {
    // A DAILY template overdue 3 days (2026-08-01 through 2026-08-03, checked
    // as of 2026-08-05) — but the mock PATCH handler simulates another
    // session's concurrent run having already advanced past the SECOND
    // occurrence's expected value, so the CAS on that advance call fails.
    // The service must create exactly 2 transactions and stop, not 3+.
    var postCount = 0;
    var patchCount = 0;

    mockServer.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/recurring_transactions')) {
        await request.drain<void>();
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
              'amount': 1000,
              'interval_rule': 'DAILY',
              'next_run_at': DateTime.utc(2026, 8, 1).toIso8601String(),
              'memo': null,
            },
          ]));
        await request.response.close();
      } else if (request.method == 'POST' && request.uri.path.endsWith('/transactions')) {
        postCount++;
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.created
          ..headers.contentType = ContentType.json
          ..write(jsonEncode([
            {
              'id': 'txn-$postCount', 'account_id': 'account-1', 'category_id': 'category-1',
              'member_id': 'member-1', 'type': 'expense', 'amount': 1000,
              'occurred_at': DateTime.now().toUtc().toIso8601String(), 'source': 'recurring_auto',
              'memo': null, 'merchant': null,
            },
          ]));
        await request.response.close();
      } else if (request.method == 'PATCH' && request.uri.path.endsWith('/recurring_transactions')) {
        patchCount++;
        await request.drain<void>();
        if (patchCount == 2) {
          // simulate another session having already moved next_run_at past this point
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(<dynamic>[]));
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode([
              {'id': 'rt-1'},
            ]));
        }
        await request.response.close();
      }
    });

    final count = await service.run('household-1', now: DateTime.utc(2026, 8, 5));

    expect(count, 2);
    expect(postCount, 2);
    expect(patchCount, 2);
  });
}
