import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';

final categoryRepository = CategoryRepository(client: supabase);

class CategoryScreen extends StatefulWidget {
  const CategoryScreen({super.key, required this.householdId, CategoryRepository? repository})
      : _repository = repository;

  final String householdId;
  final CategoryRepository? _repository;

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  late final CategoryRepository _repository = widget._repository ?? categoryRepository;
  final _nameController = TextEditingController();
  String _type = 'expense';
  List<Category>? _categories;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final categories = await _repository.list(widget.householdId);
      if (!mounted) return;
      setState(() => _categories = categories);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '카테고리를 불러오지 못했어요');
    }
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    try {
      await _repository.create(widget.householdId, name, _type);
      _nameController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '카테고리 추가에 실패했어요');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    return Scaffold(
      appBar: AppBar(title: const Text('카테고리 관리')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: categories == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: categories.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(categories[i].name),
                      subtitle: Text(categories[i].type == 'expense' ? '지출' : '수입'),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: '새 카테고리'),
                  ),
                ),
                DropdownButton<String>(
                  value: _type,
                  items: const [
                    DropdownMenuItem(value: 'expense', child: Text('지출')),
                    DropdownMenuItem(value: 'income', child: Text('수입')),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'expense'),
                ),
                IconButton(icon: const Icon(Icons.add), onPressed: _add),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
