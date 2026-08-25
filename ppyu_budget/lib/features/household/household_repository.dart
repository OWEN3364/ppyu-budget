import 'package:supabase_flutter/supabase_flutter.dart';

class HouseholdRepository {
  HouseholdRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<String> createHousehold() async {
    final result = await _client.rpc('create_household_and_owner');
    return result as String;
  }

  Future<String> createInviteCode(String householdId) async {
    final result = await _client.rpc(
      'create_invite_code',
      params: {'p_household_id': householdId},
    );
    return result as String;
  }

  Future<String> joinHousehold(String code) async {
    final result = await _client.rpc(
      'join_household',
      params: {'p_code': code},
    );
    return result as String;
  }

  Future<String?> getMyHousehold() async {
    final result = await _client.rpc('get_my_household');
    return result as String?;
  }
}
