import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';

class TransactionRepository {
  TransactionRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<LedgerTransaction>> list(String householdId) async {
    final rows = await _client
        .from('transactions')
        .select()
        .eq('household_id', householdId)
        .order('occurred_at', ascending: false);
    return rows.map(LedgerTransaction.fromJson).toList();
  }

  Future<LedgerTransaction> create({
    required String householdId,
    required String accountId,
    required String categoryId,
    required String memberId,
    required String type,
    required int amount,
    String? memo,
  }) async {
    final rows = await _client.from('transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'member_id': memberId,
      'type': type,
      'amount': amount,
      'memo': memo,
    }).select();
    return LedgerTransaction.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('transactions').delete().eq('id', id);
  }
}
