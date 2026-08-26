import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';

class TransactionRepository {
  TransactionRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<LedgerTransaction>> list(String householdId) async {
    final rows = await _client
        .from('transactions')
        .select('*, transaction_tags(tag_id)')
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
    String? merchant,
    String source = 'manual',
    List<String> tagIds = const [],
  }) async {
    final rows = await _client.from('transactions').insert({
      'household_id': householdId,
      'account_id': accountId,
      'category_id': categoryId,
      'member_id': memberId,
      'type': type,
      'amount': amount,
      'memo': memo,
      'merchant': merchant,
      'source': source,
    }).select();
    final transaction = LedgerTransaction.fromJson(rows.first);
    // a brand-new row can't have existing tags, so there's nothing to clear —
    // skip setTags entirely rather than firing a DELETE that can only ever
    // affect zero rows
    if (tagIds.isNotEmpty) {
      await setTags(transaction.id, tagIds);
    }
    return LedgerTransaction.fromJson({...rows.first, 'transaction_tags': tagIds.map((id) => {'tag_id': id}).toList()});
  }

  Future<LedgerTransaction> update({
    required String id,
    required String accountId,
    required String categoryId,
    required String type,
    required int amount,
    String? memo,
    String? merchant,
    List<String> tagIds = const [],
  }) async {
    final rows = await _client
        .from('transactions')
        .update({
          'account_id': accountId,
          'category_id': categoryId,
          'type': type,
          'amount': amount,
          'memo': memo,
          'merchant': merchant,
        })
        .eq('id', id)
        .select();
    await setTags(id, tagIds);
    return LedgerTransaction.fromJson({...rows.first, 'transaction_tags': tagIds.map((tagId) => {'tag_id': tagId}).toList()});
  }

  /// Replaces every tag on [transactionId] with [tagIds] (delete-then-insert
  /// — simpler and more idempotent than diffing old vs new tag sets).
  Future<void> setTags(String transactionId, List<String> tagIds) async {
    await _client.from('transaction_tags').delete().eq('transaction_id', transactionId);
    if (tagIds.isEmpty) return;
    await _client.from('transaction_tags').insert(
          tagIds.map((tagId) => {'transaction_id': transactionId, 'tag_id': tagId}).toList(),
        );
  }

  Future<void> delete(String id) async {
    await _client.from('transactions').delete().eq('id', id);
  }
}
