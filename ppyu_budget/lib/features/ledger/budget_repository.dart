import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/budget.dart';

String _monthKey(DateTime month) =>
    '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}-01';

class BudgetRepository {
  BudgetRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Budget>> list(String householdId, DateTime month) async {
    final rows = await _client
        .from('budgets')
        .select()
        .eq('household_id', householdId)
        .eq('month', _monthKey(month));
    return rows.map(Budget.fromJson).toList();
  }

  // Not a real Postgres UPSERT: PostgREST's on_conflict target can't express
  // the partial unique index that enforces "one overall (null category_id)
  // budget per household per month" (Postgres only infers a partial index
  // via ON CONFLICT when the conflict target repeats its WHERE predicate,
  // which PostgREST's on_conflict param has no way to specify). A plain
  // check-then-write avoids relying on conflict inference entirely.
  Future<Budget> upsert({
    required String householdId,
    String? categoryId,
    required DateTime month,
    required int amount,
  }) async {
    var query = _client
        .from('budgets')
        .select('id')
        .eq('household_id', householdId)
        .eq('month', _monthKey(month));
    query = categoryId == null
        ? query.isFilter('category_id', null)
        : query.eq('category_id', categoryId);
    final rows = await query;

    if (rows.isNotEmpty) {
      final updated = await _client
          .from('budgets')
          .update({'amount': amount})
          .eq('id', rows.first['id'] as String)
          .select();
      return Budget.fromJson(updated.first);
    }

    final inserted = await _client.from('budgets').insert({
      'household_id': householdId,
      'category_id': categoryId,
      'month': _monthKey(month),
      'amount': amount,
    }).select();
    return Budget.fromJson(inserted.first);
  }
}
