import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/tag.dart';

class TagRepository {
  TagRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Tag>> list(String householdId) async {
    final rows = await _client.from('tags').select().eq('household_id', householdId);
    return rows.map(Tag.fromJson).toList();
  }

  Future<Tag> create(String householdId, String name) async {
    final rows = await _client.from('tags').insert({
      'household_id': householdId,
      'name': name,
    }).select();
    return Tag.fromJson(rows.first);
  }

  Future<void> delete(String tagId) async {
    await _client.from('tags').delete().eq('id', tagId);
  }
}
