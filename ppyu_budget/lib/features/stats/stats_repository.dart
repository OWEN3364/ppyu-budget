import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/stats/models/category_summary.dart';
import 'package:ppyu_budget/features/stats/models/spending_recommendation.dart';

String _monthKey(DateTime month) =>
    '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}-01';

class StatsRepository {
  StatsRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<CategorySummary>> monthlyCategorySummary(String householdId, DateTime month) async {
    final result = await _client.rpc('get_monthly_category_summary', params: {
      'p_household_id': householdId,
      'p_month': _monthKey(month),
    });
    return (result as List).map((r) => CategorySummary.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<List<SpendingRecommendation>> spendingRecommendations(String householdId, DateTime month) async {
    final result = await _client.rpc('get_spending_recommendations', params: {
      'p_household_id': householdId,
      'p_month': _monthKey(month),
    });
    return (result as List).map((r) => SpendingRecommendation.fromJson(r as Map<String, dynamic>)).toList();
  }
}
