import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/account_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late AccountRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = AccountRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches accounts for a household', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/accounts'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'a1', 'name': '신한카드', 'type': 'card'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '신한카드');
  });

  test('create posts a new account and returns it', () async {
    final future = repo.create('household-1', '현금', 'cash');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/accounts'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'name': '현금',
      'type': 'cash',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'a2', 'name': '현금', 'type': 'cash'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '현금');
    expect(result.type, 'cash');
  });
}
