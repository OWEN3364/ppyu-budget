import 'package:ppyu_budget/core/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/account_repository.dart';
import 'package:ppyu_budget/features/ledger/models/account.dart';

final accountRepository = AccountRepository(client: supabase);

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.householdId, AccountRepository? repository})
      : _repository = repository;

  final String householdId;
  final AccountRepository? _repository;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final AccountRepository _repository = widget._repository ?? accountRepository;
  final _nameController = TextEditingController();
  String _type = 'card';
  List<Account>? _accounts;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final accounts = await _repository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '계좌 목록을 불러오지 못했어요');
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
      await _repository.create(widget.householdId, name, _type);
      _nameController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '계좌 추가에 실패했어요');
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
    final accounts = _accounts;
    return Scaffold(
      appBar: AppBar(title: const Text('계좌/카드 관리')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.error)),
          Expanded(
            child: accounts == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: accounts.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(accounts[i].name),
                      subtitle: Text(accounts[i].type),
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
                    decoration: const InputDecoration(labelText: '계좌/카드 이름'),
                  ),
                ),
                DropdownButton<String>(
                  value: _type,
                  items: const [
                    DropdownMenuItem(value: 'card', child: Text('카드')),
                    DropdownMenuItem(value: 'bank', child: Text('계좌')),
                    DropdownMenuItem(value: 'cash', child: Text('현금')),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'card'),
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
