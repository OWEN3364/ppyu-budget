import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/stats/stats_repository.dart';

void main() {
  late HttpServer mockServer;
  late SupabaseClient client;
  late StatsRepository repo;

  setUp(() async {
    mockServer = await HttpServer.bind('localhost', 0);
    final supabaseUrl = 'http://${mockServer.address.host}:${mockServer.port}';
    client = SupabaseClient(supabaseUrl, 'test-anon-key');
    repo = StatsRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
    await mockServer.close(force: true);
  });

  test('monthlyCategorySummary calls the RPC with a normalized month key', () async {
    final future = repo.monthlyCategorySummary('household-1', DateTime(2026, 8, 15));

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/get_monthly_category_summary'));
    final bodyStr = await utf8.decodeStream(request);
    expect(jsonDecode(bodyStr), {'p_household_id': 'household-1', 'p_month': '2026-08-01'});
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {'category_id': 'c1', 'category_name': '식비', 'type': 'expense', 'total_amount': 150000},
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.totalAmount, 150000);
  });

  test('spendingRecommendations parses change_ratio', () async {
    final future = repo.spendingRecommendations('household-1', DateTime(2026, 8, 15));

    final request = await mockServer.first;
    expect(request.uri.path, endsWith('/rpc/get_spending_recommendations'));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode([
        {
          'category_id': 'c1',
          'category_name': '식비',
          'current_amount': 150000,
          'previous_amount': 100000,
          'change_ratio': 50.0,
        },
      ]));
    await request.response.close();

    final result = await future;
    expect(result, hasLength(1));
    expect(result.first.changeRatio, 50.0);
  });
}
