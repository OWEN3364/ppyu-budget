import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/savings_goal_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late SavingsGoalRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = SavingsGoalRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('list fetches a household\'s savings goals', () async {
    final future = repo.list('household-1');

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/savings_goals'));
    expect(request.uri.queryParameters['household_id'], 'eq.household-1');
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 's1',
          'name': '여행자금',
          'target_amount': 3000000,
          'current_amount': 500000,
          'target_date': '2027-01-01',
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.name, '여행자금');
    expect(result.first.targetAmount, 3000000);
  });

  test('create posts a new savings goal', () async {
    final future = repo.create(
      householdId: 'household-1',
      name: '결혼자금',
      targetAmount: 10000000,
    );

    final request = await mockServer.first;
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {
      'household_id': 'household-1',
      'name': '결혼자금',
      'target_amount': 10000000,
      'target_date': null,
    });
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'id': 's2',
          'name': '결혼자금',
          'target_amount': 10000000,
          'current_amount': 0,
          'target_date': null,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result.name, '결혼자금');
    expect(result.currentAmount, 0);
  });
}
