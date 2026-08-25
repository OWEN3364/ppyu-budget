import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late CategoryRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = CategoryRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches categories for a household filtered by type', () async {
    final future = repo.list('household-1', type: 'expense');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/categories'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    expect(request.uri.queryParameters['type'], 'eq.expense');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'c1', 'name': '식비', 'type': 'expense', 'icon': null, 'is_default': true},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '식비');
    expect(result.first.isDefault, isTrue);
  });

  test('create posts a new custom category', () async {
    final future = repo.create('household-1', '반려동물', 'expense');

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'name': '반려동물',
      'type': 'expense',
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'c2', 'name': '반려동물', 'type': 'expense', 'icon': null, 'is_default': false},
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '반려동물');
    expect(result.isDefault, isFalse);
  });
}
