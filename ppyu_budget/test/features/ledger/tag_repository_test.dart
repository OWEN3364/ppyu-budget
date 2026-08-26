import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/tag_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late TagRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = TagRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s tags', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/tags'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'tag-1', 'name': '배달'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '배달');
  });

  test('create posts a new tag', () async {
    final future = repo.create('household-1', '여행');

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'household_id': 'household-1', 'name': '여행'});
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'id': 'tag-2', 'name': '여행'},
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '여행');
  });

  test('delete removes a tag by id', () async {
    final future = repo.delete('tag-1');

    final request = await mockServer.first;
    expect(request.method, 'DELETE');
    expect(request.uri.path, endsWith('/tags'));
    expect(request.uri.queryParameters['id'], 'eq.tag-1');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();

    await future;
  });
}
