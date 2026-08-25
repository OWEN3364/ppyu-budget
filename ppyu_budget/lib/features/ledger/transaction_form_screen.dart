import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/models/account.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';
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
  String? _accountId;
  String? _categoryId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final accounts = await accountRepository.list(widget.householdId);
    final categories = await categoryRepository.list(widget.householdId, type: _type);
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _categories = categories;
      _accountId = accounts.isNotEmpty ? accounts.first.id : null;
      _categoryId = categories.isNotEmpty ? categories.first.id : null;
    });
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
