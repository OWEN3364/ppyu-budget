import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/models/account.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;

class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({
    super.key,
    required this.householdId,
    required this.transaction,
  });

  final String householdId;
  final LedgerTransaction transaction;

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  late final _amountController =
      TextEditingController(text: widget.transaction.amount.toString());
  late final _memoController = TextEditingController(text: widget.transaction.memo ?? '');
  late final _merchantController =
      TextEditingController(text: widget.transaction.merchant ?? '');
  late String _type = widget.transaction.type;
  late String? _accountId = widget.transaction.accountId;
  late String? _categoryId = widget.transaction.categoryId;
  List<Account>? _accounts;
  List<Category>? _categories;
  String? _error;
  bool _saving = false;

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
      if (!mounted || requestedType != _type) return;
      setState(() {
        _accounts = accounts;
        _categories = categories;
        _accountId = accounts.any((a) => a.id == _accountId)
            ? _accountId
            : (accounts.isNotEmpty ? accounts.first.id : null);
        _categoryId = categories.any((c) => c.id == _categoryId)
            ? _categoryId
            : (categories.isNotEmpty ? categories.first.id : null);
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestedType != _type) return;
      setState(() => _error = '옵션을 불러오지 못했어요');
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
      await transactionRepository.update(
        id: widget.transaction.id,
        accountId: accountId,
        categoryId: categoryId,
        type: _type,
        amount: amount,
        memo: _memoController.text.trim().isEmpty ? null : _memoController.text.trim(),
        merchant: _merchantController.text.trim().isEmpty ? null : _merchantController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 수정에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    // reuses _saving as the single busy flag so a double-tap (or a
    // save-then-delete) can't fire two writes
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await transactionRepository.delete(widget.transaction.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 삭제에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _memoController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final categories = _categories;
    if (accounts == null || categories == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('거래 상세')),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
            : const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('거래 상세'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _saving ? null : _delete,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (widget.transaction.source == 'notification_auto')
              const Text('알림에서 자동으로 채워졌어요. 틀린 부분이 있으면 고쳐주세요.',
                  style: TextStyle(color: Colors.grey)),
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
            TextField(
              controller: _merchantController,
              decoration: const InputDecoration(labelText: '사용처'),
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
