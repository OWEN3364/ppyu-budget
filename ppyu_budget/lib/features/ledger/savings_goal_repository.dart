import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/savings_goal.dart';

class SavingsGoalRepository {
  SavingsGoalRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<SavingsGoal>> list(String householdId) async {
    final rows = await _client
        .from('savings_goals')
        .select()
        .eq('household_id', householdId);
    return rows.map(SavingsGoal.fromJson).toList();
  }

  Future<SavingsGoal> create({
    required String householdId,
    required String name,
    required int targetAmount,
    DateTime? targetDate,
  }) async {
    final rows = await _client.from('savings_goals').insert({
      'household_id': householdId,
      'name': name,
      'target_amount': targetAmount,
      'target_date': targetDate == null
          ? null
          : '${targetDate.year.toString().padLeft(4, '0')}-${targetDate.month.toString().padLeft(2, '0')}-${targetDate.day.toString().padLeft(2, '0')}',
    }).select();
    return SavingsGoal.fromJson(rows.first);
  }
}
