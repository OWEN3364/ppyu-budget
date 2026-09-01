import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';

class RecurringTransactionRepository {
  RecurringTransactionRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<RecurringTransaction>> list(String householdId) async {
    final rows = await _client.from('recurring_transactions').select().eq('household_id', householdId);
    return rows.map(RecurringTransaction.fromJson).toList();
  }

  Future<RecurringTransaction> create({
    required String householdId,
    required String accountId,
    required String categoryId,
    required String createdBy,
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime nextRunAt,
    String? memo,
  }) async {
    final rows = await _client.from('recurring_transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'created_by': createdBy,
      'type': type,
      'amount': amount,
      'interval_rule': intervalRule,
      'next_run_at': nextRunAt.toUtc().toIso8601String(),
      'memo': memo,
    }).select();
    return RecurringTransaction.fromJson(rows.first);
  }

  Future<RecurringTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime nextRunAt,
    String? memo,
  }) async {
    final rows = await _client
        .from('recurring_transactions')
        .update({
          'account_id': accountId,
          'category_id': categoryId,
          'type': type,
          'amount': amount,
          'interval_rule': intervalRule,
          'next_run_at': nextRunAt.toUtc().toIso8601String(),
          'memo': memo,
        })
        .eq('id', id)
        .select();
    return RecurringTransaction.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('recurring_transactions').delete().eq('id', id);
  }

  /// Advances only `next_run_at`, leaving every other field untouched — used
  /// by the catch-up service after each occurrence it successfully creates,
  /// so a mid-batch failure never loses the progress already made.
  Future<void> advanceNextRunAt(String id, DateTime nextRunAt) async {
    await _client
        .from('recurring_transactions')
        .update({'next_run_at': nextRunAt.toUtc().toIso8601String()})
        .eq('id', id);
  }
}
