import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  setUp(() async {
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
    notificationController.add(const RawNotification(
      packageName: 'com.samsung.android.spay',
      text: '5,000원 승인 스타벅스',
    ));

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

  test('ignores a notification from an unrecognized source', () async {
    service.start();
    notificationController.add(const RawNotification(
      packageName: 'com.some.other.app',
      text: '5,000원 승인 어딘가',
    ));

    // give the stream a moment to process, then confirm no request was made
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mockServer.first.timeout(const Duration(milliseconds: 50)), throwsA(anything));
  });
}
