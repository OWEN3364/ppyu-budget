// Tests HouseholdRepository against a REAL SupabaseClient pointed at a local
// HttpServer, instead of mocking SupabaseClient.rpc() directly.
//
// Why: SupabaseClient.rpc() returns PostgrestFilterBuilder<T>, a concrete
// class that IMPLEMENTS Future<T> but is not literally a Future<T> instance
// (postgrest-2.9.1/lib/src/postgrest_builder.dart:150). mocktail's
// `.thenAnswer((_) async => value)` produces a real Future<T>, which is not
// assignable where PostgrestFilterBuilder<T> is statically required, so that
// pattern (as originally suggested) doesn't compile.
//
// Instead we build a real SupabaseClient against a local HttpServer, mirroring
// the pattern the `supabase` package itself uses in its own test suite
// (supabase-2.16.1/test/mock_test.dart, client_test.dart). This exercises the
// real rpc()/PostgrestFilterBuilder await machinery while only faking the
// network layer.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late HouseholdRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl =
        'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = HouseholdRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('createHousehold calls the create_household_and_owner RPC', () async {
    final future = repo.createHousehold();

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/create_household_and_owner'));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode('household-id-123'));
    await request.response.close();

    expect(await future, 'household-id-123');
  });

  test('joinHousehold passes the code to the join_household RPC', () async {
    final future = repo.joinHousehold('123456');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/join_household'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'p_code': '123456'});
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode('household-id-456'));
    await request.response.close();

    expect(await future, 'household-id-456');
  });

  test('createInviteCode passes the household id to the create_invite_code RPC',
      () async {
    final future = repo.createInviteCode('household-id-123');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/create_invite_code'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'p_household_id': 'household-id-123'});
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode('ABC123'));
    await request.response.close();

    expect(await future, 'ABC123');
  });
}
