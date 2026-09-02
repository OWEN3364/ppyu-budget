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

  Future<void> setMyNickname(String householdId, String nickname) async {
    await _client.rpc('set_my_nickname', params: {
      'p_household_id': householdId,
      'p_nickname': nickname,
    });
  }

  /// The caller's own household_members.id within [householdId] — used
  /// wherever code needs to know "which member is me" (e.g. defaulting a
  /// new recurring-transaction template's owner, or splitting the
  /// recurring-transaction todo list into "나"/"배우자").
  Future<String> myMemberId(String householdId) async {
    final row = await _client
        .from('household_members')
        .select('id')
        .eq('household_id', householdId)
        .eq('user_id', _client.auth.currentUser!.id)
        .single();
    return row['id'] as String;
  }

  Future<Map<String, String>> nicknamesByMemberId(String householdId) async {
    final rows = await _client
        .from('household_members')
        .select('id, nickname')
        .eq('household_id', householdId);
    return {
      for (final row in rows)
        row['id'] as String:
            (row['nickname'] as String?)?.isNotEmpty == true ? row['nickname'] as String : '가족 구성원',
    };
  }
}
