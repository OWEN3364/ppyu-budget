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

  /// Updates an existing template. [nextRunAt] is optional and the key is
  /// omitted from the payload entirely when null — an edit form that didn't
  /// touch the date must NOT write back the (possibly stale) value it loaded,
  /// or it would roll the schedule backwards past occurrences an in-flight
  /// catch-up already created, and the next catch-up would replay them all.
  Future<RecurringTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String type,
    required int amount,
    required String intervalRule,
    DateTime? nextRunAt,
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
          if (nextRunAt != null) 'next_run_at': nextRunAt.toUtc().toIso8601String(),
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
  /// by the catch-up service after each occurrence it successfully creates.
  /// This is a compare-and-swap: the update only applies if `next_run_at`
  /// still equals [expectedCurrentNextRunAt] (the value this caller last
  /// read). Returns whether the swap succeeded. If it returns false, another
  /// session already advanced this template past this point — the caller
  /// must stop processing this template rather than keep going, or it would
  /// create further duplicate transactions on top of the one already made
  /// for the occurrence that just triggered this call.
  Future<bool> advanceNextRunAt(
    String id,
    DateTime nextRunAt, {
    required DateTime expectedCurrentNextRunAt,
  }) async {
    final rows = await _client
        .from('recurring_transactions')
        .update({'next_run_at': nextRunAt.toUtc().toIso8601String()})
        .eq('id', id)
        .eq('next_run_at', expectedCurrentNextRunAt.toUtc().toIso8601String())
        .select();
    return rows.isNotEmpty;
  }
}
