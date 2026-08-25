import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/account.dart';

class AccountRepository {
  AccountRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Account>> list(String householdId) async {
    final rows = await _client
        .from('accounts')
        .select()
        .eq('household_id', householdId);
    return rows.map(Account.fromJson).toList();
  }

  Future<Account> create(String householdId, String name, String type) async {
    final rows = await _client.from('accounts').insert({
      'household_id': householdId,
      'name': name,
      'type': type,
    }).select();
    return Account.fromJson(rows.first);
  }
}
