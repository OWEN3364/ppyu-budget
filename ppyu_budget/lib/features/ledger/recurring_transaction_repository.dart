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
    required String ownerMemberId,
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime startAt,
    bool autoRegister = false,
    String? memo,
  }) async {
    final rows = await _client.from('recurring_transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'created_by': createdBy,
      'owner_member_id': ownerMemberId,
      'type': type,
      'amount': amount,
      'interval_rule': intervalRule,
      'start_at': startAt.toUtc().toIso8601String(),
      'auto_register': autoRegister,
      'memo': memo,
    }).select();
    return RecurringTransaction.fromJson(rows.first);
  }

  /// Updates an existing template. Unlike the old `next_run_at`-based
  /// design, `start_at` is a fixed calculation anchor, not a pointer another
  /// session might be mid-advancing — "done" is now derived from whether a
  /// matching transaction exists (the unique index from migration 0011),
  /// not from this column. So unlike the old `update()`, `startAt` is a
  /// plain required field here — no CAS, no optional-omit-when-unchanged
  /// dance needed.
  ///
  /// The unique index guarantees no single `(recurring_transaction_id,
  /// occurred_at)` pair is ever literally duplicated — but that is a
  /// narrower promise than "editing is safe". Moving `start_at` or changing
  /// `interval_rule` recomputes the whole occurrence series onto dates that
  /// have no transaction yet, so on an `auto_register` template the next
  /// catch-up run silently back-fills all of them (a MONTHLY template moved
  /// from the 1st to the 5th grows a second rent charge in every past
  /// month). The caller (`RecurringTransactionFormScreen._save`) therefore
  /// confirms with the user before updating when `autoRegister` is true and
  /// `startAt` or `intervalRule` actually changed.
  Future<RecurringTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String ownerMemberId,
    required String type,
    required int amount,
    required String intervalRule,
    required DateTime startAt,
    required bool autoRegister,
    String? memo,
  }) async {
    final rows = await _client
        .from('recurring_transactions')
        .update({
          'account_id': accountId,
          'category_id': categoryId,
          'owner_member_id': ownerMemberId,
          'type': type,
          'amount': amount,
          'interval_rule': intervalRule,
          'start_at': startAt.toUtc().toIso8601String(),
          'auto_register': autoRegister,
          'memo': memo,
        })
        .eq('id', id)
        .select();
    return RecurringTransaction.fromJson(rows.first);
  }

  Future<void> delete(String id) async {
    await _client.from('recurring_transactions').delete().eq('id', id);
  }
}
