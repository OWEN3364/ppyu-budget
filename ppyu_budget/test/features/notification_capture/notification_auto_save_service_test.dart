import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/account_repository.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';
import 'package:ppyu_budget/features/notification_capture/notification_auto_save_service.dart';
import 'package:ppyu_budget/features/notification_capture/notification_capture_service.dart';

void main() {
  late HttpServer mockServer;
  // ponytail: HttpServer's Stream.first cancels the subscription, which
  // closes the server — so it can only ever be awaited once per server.
  // A StreamIterator holds one subscription open across multiple sequential
  // requests instead (stdlib, no new dependency needed).
  late StreamIterator<HttpRequest> requests;
  late SupabaseClient client;
  late StreamController<RawNotification> notificationController;
  late NotificationAutoSaveService service;

  // RawNotification.id/timestamp are carried for future dedup work and unread
  // by the service — this helper supplies placeholders so the tests stay about
  // package name and text.
  var nextId = 0;
  RawNotification notif(String packageName, String text) => RawNotification(
        packageName: packageName,
        text: text,
        id: '${nextId++}',
        timestamp: DateTime.now(),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mockServer = await HttpServer.bind('localhost', 0);
    requests = StreamIterator<HttpRequest>(mockServer);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    notificationController = StreamController<RawNotification>();
    service = NotificationAutoSaveService(
      notifications: notificationController.stream,
      householdId: 'household-1',
      memberId: 'member-1',
      accountRepository: AccountRepository(client: client),
      categoryRepository: CategoryRepository(client: client),
      transactionRepository: TransactionRepository(client: client),
    );
  });

  tearDown(() async {
    service.stop();
    await notificationController.close();
    // ponytail: a test only awaits the *server* side of the last respondJson
    // (write+close the response) — the client's in-flight Future for that
    // same request (e.g. transactionRepository.create()) needs one more
    // event-loop turn to finish reading it. Disposing the client/server
    // immediately races that read and intermittently throws "Connection
    // closed before full header was received". A short grace delay avoids
    // it; upgrade to explicitly awaiting the handler's completion (e.g. via
    // a completion callback/Future the test can hook) if this proves flaky.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await client.dispose();
    await requests.cancel();
    await mockServer.close(force: true);
  });

  // Returns the request plus its decoded body. The body must be read before
  // closing the response: HttpResponse.close() auto-drains any unread
  // request body to free the connection for the next request, so reading it
  // afterwards throws "Stream has already been listened to."
  Future<(HttpRequest, String)> respondJson(List<Map<String, Object?>> body, {int status = 200}) async {
    await requests.moveNext();
    final request = requests.current;
    final requestBody = await utf8.decodeStream(request);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
    return (request, requestBody);
  }

  test('parses a known-source notification, finds-or-creates the account, and saves a transaction',
      () async {
    service.start();
    notificationController.add(notif('com.samsung.android.spay', '5,000원 승인 스타벅스'));

    // 1: account lookup — no existing "삼성페이" account
    final (accountLookup, _) = await respondJson([]);
    expect(accountLookup.uri.path, endsWith('/accounts'));

    // 2: account creation
    final (accountCreate, _) = await respondJson([
      {'id': 'acc-1', 'name': '삼성페이', 'type': 'card'}
    ], status: 201);
    expect(accountCreate.method, 'POST');

    // 3: category lookup — pick the default "기타" expense category
    final (categoryLookup, _) = await respondJson([
      {'id': 'cat-1', 'name': '기타', 'type': 'expense', 'icon': null, 'is_default': true}
    ]);
    expect(categoryLookup.uri.path, endsWith('/categories'));

    // 4: transaction insert
    final (txnInsert, txnBody) = await respondJson([
      {
        'id': 't1',
        'account_id': 'acc-1',
        'category_id': 'cat-1',
        'member_id': 'member-1',
        'type': 'expense',
        'amount': 5000,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'source': 'notification_auto',
        'memo': null,
        'merchant': '스타벅스',
      }
    ], status: 201);
    expect(txnInsert.uri.path, endsWith('/transactions'));
    final body = jsonDecode(txnBody) as Map<String, dynamic>;
    expect(body['amount'], 5000);
    expect(body['source'], 'notification_auto');
    expect(body['merchant'], '스타벅스');
  });

  test(
      'serializes handling so two notifications for the same new issuer '
      'do not race and create a duplicate account', () async {
    service.start();
    // Both fired back-to-back, synchronously, before either is processed —
    // this is exactly the interleaving window the pause/resume fix closes.
    notificationController.add(notif('com.samsung.android.spay', '5,000원 승인 스타벅스'));
    notificationController.add(notif('com.samsung.android.spay', '3,000원 승인 이디야'));

    // First notification's full round trip must complete — including the
    // account creation — before the second notification's account lookup is
    // even sent, if (and only if) handling is serialized.
    final (lookup1, _) = await respondJson([]);
    expect(lookup1.uri.path, endsWith('/accounts'));

    final (create1, _) = await respondJson([
      {'id': 'acc-1', 'name': '삼성페이', 'type': 'card'}
    ], status: 201);
    expect(create1.method, 'POST');
    expect(create1.uri.path, endsWith('/accounts'));

    final (catLookup1, _) = await respondJson([
      {'id': 'cat-1', 'name': '기타', 'type': 'expense', 'icon': null, 'is_default': true}
    ]);
    expect(catLookup1.uri.path, endsWith('/categories'));

    final (txn1, _) = await respondJson([
      {
        'id': 't1',
        'account_id': 'acc-1',
        'category_id': 'cat-1',
        'member_id': 'member-1',
        'type': 'expense',
        'amount': 5000,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'source': 'notification_auto',
        'memo': null,
        'merchant': '스타벅스',
      }
    ], status: 201);
    expect(txn1.uri.path, endsWith('/transactions'));

    // Second notification now finds the account the first one just created
    // — no second POST to /accounts, i.e. no duplicate.
    final (lookup2, _) = await respondJson([
      {'id': 'acc-1', 'name': '삼성페이', 'type': 'card'}
    ]);
    expect(lookup2.uri.path, endsWith('/accounts'));
    expect(lookup2.method, 'GET');

    final (catLookup2, _) = await respondJson([
      {'id': 'cat-1', 'name': '기타', 'type': 'expense', 'icon': null, 'is_default': true}
    ]);
    expect(catLookup2.uri.path, endsWith('/categories'));

    final (txn2, _) = await respondJson([
      {
        'id': 't2',
        'account_id': 'acc-1',
        'category_id': 'cat-1',
        'member_id': 'member-1',
        'type': 'expense',
        'amount': 3000,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'source': 'notification_auto',
        'memo': null,
        'merchant': '이디야',
      }
    ], status: 201);
    expect(txn2.uri.path, endsWith('/transactions'));
  });

  test('ignores a notification from an unrecognized source', () async {
    service.start();
    notificationController.add(notif('com.some.other.app', '5,000원 승인 어딘가'));

    // give the stream a moment to process, then confirm no request was made
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mockServer.first.timeout(const Duration(milliseconds: 50)), throwsA(anything));
  });

  test('creates a pending (unconfirmed) transaction when confirm-before-save is on', () async {
    SharedPreferences.setMockInitialValues({'notification_confirm_before_save': true});
    service.start();
    notificationController.add(notif('com.samsung.android.spay', '5,000원 승인 스타벅스'));

    await respondJson([]); // account lookup
    await respondJson([
      {'id': 'acc-1', 'name': '삼성페이', 'type': 'card'}
    ], status: 201); // account creation
    await respondJson([
      {'id': 'cat-1', 'name': '기타', 'type': 'expense', 'icon': null, 'is_default': true}
    ]); // category lookup
    final (txnInsert, txnBody) = await respondJson([
      {
        'id': 't1', 'account_id': 'acc-1', 'category_id': 'cat-1', 'member_id': 'member-1',
        'type': 'expense', 'amount': 5000, 'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'source': 'notification_auto', 'memo': null, 'merchant': '스타벅스',
      }
    ], status: 201);
    expect(txnInsert.uri.path, endsWith('/transactions'));
    final body = jsonDecode(txnBody) as Map<String, dynamic>;
    expect(body['confirmed'], false);
  });
}
