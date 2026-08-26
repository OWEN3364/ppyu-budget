import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/models/account.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';
import 'package:ppyu_budget/features/ledger/models/tag.dart';
import 'package:ppyu_budget/features/ledger/tag_management_screen.dart' show tagRepository;
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

final transactionRepository = TransactionRepository(client: supabase);

class TransactionFormScreen extends StatefulWidget {
  const TransactionFormScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends State<TransactionFormScreen> {
  final _amountController = TextEditingController();
  final _memoController = TextEditingController();
  String _type = 'expense';
  List<Account>? _accounts;
  List<Category>? _categories;
  List<Tag>? _tags;
  String? _accountId;
  String? _categoryId;
  String? _error;
  bool _saving = false;
  final Set<String> _selectedTagIds = {};

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    // Guards against an out-of-order response: switching type twice quickly
    // fires two loads, and the slower (older) one must not overwrite the
    // newer one's categories.
    final requestedType = _type;
    try {
      final accounts = await accountRepository.list(widget.householdId);
      final categories = await categoryRepository.list(widget.householdId, type: _type);
      final tags = _tags ?? await tagRepository.list(widget.householdId);
      if (!mounted || requestedType != _type) return;
      setState(() {
        _accounts = accounts;
        _categories = categories;
        _tags = tags;
        _accountId = accounts.isNotEmpty ? accounts.first.id : null;
        _categoryId = categories.isNotEmpty ? categories.first.id : null;
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestedType != _type) return;
      setState(() => _error = '계좌/카테고리/태그를 불러오지 못했어요');
    }
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amountController.text.trim());
    final accountId = _accountId;
    final categoryId = _categoryId;
    if (amount == null || amount <= 0 || accountId == null || categoryId == null) {
      setState(() => _error = '금액, 계좌, 카테고리를 확인해주세요');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final memberRow = await supabase
          .from('household_members')
          .select('id')
          .eq('household_id', widget.householdId)
          .eq('user_id', supabase.auth.currentUser!.id)
          .single();
      await transactionRepository.create(
        householdId: widget.householdId,
        accountId: accountId,
        categoryId: categoryId,
        memberId: memberRow['id'] as String,
        type: _type,
        amount: amount,
        memo: _memoController.text.trim().isEmpty ? null : _memoController.text.trim(),
        tagIds: _selectedTagIds.toList(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 저장에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final categories = _categories;
    if (accounts == null || categories == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('거래 추가')),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
            : const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('거래 추가')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButton<String>(
              value: _type,
              items: const [
                DropdownMenuItem(value: 'expense', child: Text('지출')),
                DropdownMenuItem(value: 'income', child: Text('수입')),
              ],
              onChanged: (v) {
                setState(() => _type = v ?? 'expense');
                _loadOptions();
              },
            ),
            TextField(
              controller: _amountController,
              decoration: const InputDecoration(labelText: '금액'),
              keyboardType: TextInputType.number,
            ),
            if (accounts.isNotEmpty)
              DropdownButton<String>(
                value: _accountId,
                items: accounts
                    .map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
                    .toList(),
                onChanged: (v) => setState(() => _accountId = v),
              ),
            if (categories.isNotEmpty)
              DropdownButton<String>(
                value: _categoryId,
                items: categories
                    .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
                    .toList(),
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            if (_tags != null && _tags!.isNotEmpty)
              Wrap(
                spacing: 8,
                children: _tags!.map((tag) {
                  final selected = _selectedTagIds.contains(tag.id);
                  return FilterChip(
                    label: Text(tag.name),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedTagIds.add(tag.id);
                      } else {
                        _selectedTagIds.remove(tag.id);
                      }
                    }),
                  );
                }).toList(),
              ),
            TextField(
              controller: _memoController,
              decoration: const InputDecoration(labelText: '메모(선택)'),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }
}
