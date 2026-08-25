import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';

class CategoryRepository {
  CategoryRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<List<Category>> list(String householdId, {String? type}) async {
    var query = _client.from('categories').select().eq('household_id', householdId);
    if (type != null) {
      query = query.eq('type', type);
    }
    final rows = await query;
    return rows.map(Category.fromJson).toList();
  }

  Future<Category> create(String householdId, String name, String type) async {
    final rows = await _client.from('categories').insert({
      'household_id': householdId,
      'name': name,
      'type': type,
    }).select();
    return Category.fromJson(rows.first);
  }
}
