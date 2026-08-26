import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/tag_repository.dart';
import 'package:ppyu_budget/features/ledger/models/tag.dart';

final tagRepository = TagRepository(client: supabase);

class TagManagementScreen extends StatefulWidget {
  const TagManagementScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TagManagementScreen> createState() => _TagManagementScreenState();
}

class _TagManagementScreenState extends State<TagManagementScreen> {
  final _nameController = TextEditingController();
  List<Tag>? _tags;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tags = await tagRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _tags = tags;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '태그를 불러오지 못했어요');
    }
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await tagRepository.create(widget.householdId, name);
      _nameController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '이미 있는 태그이거나 추가에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(String tagId) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await tagRepository.delete(tagId);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '태그 삭제에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    return Scaffold(
      appBar: AppBar(title: const Text('태그 관리')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: tags == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: tags.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(tags[i].name),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: _saving ? null : () => _delete(tags[i].id),
                      ),
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
                    decoration: const InputDecoration(labelText: '새 태그'),
                  ),
                ),
                IconButton(icon: const Icon(Icons.add), onPressed: _saving ? null : _add),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
