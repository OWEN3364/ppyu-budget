import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/budget_repository.dart';
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/models/budget.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';

final budgetRepository = BudgetRepository(client: supabase);

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  final _amountController = TextEditingController();
  List<Category>? _categories;
  List<Budget>? _budgets;
  String? _selectedCategoryId;
  String? _error;
  bool _saving = false;
  final _month = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final categories = await categoryRepository.list(widget.householdId, type: 'expense');
      final budgets = await budgetRepository.list(widget.householdId, _month);
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _budgets = budgets;
        _selectedCategoryId = categories.isNotEmpty ? categories.first.id : null;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '예산을 불러오지 못했어요');
    }
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amountController.text.trim());
    if (amount == null || amount < 0) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await budgetRepository.upsert(
        householdId: widget.householdId,
        categoryId: _selectedCategoryId,
        month: _month,
        amount: amount,
      );
      _amountController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '예산 저장에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    final budgets = _budgets;
    if (categories == null || budgets == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('이번 달 예산')),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
            : const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('이번 달 예산')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: ListView.builder(
              itemCount: budgets.length,
              itemBuilder: (context, i) {
                final b = budgets[i];
                final categoryName = b.categoryId == null
                    ? '전체'
                    : categories
                        .firstWhere((c) => c.id == b.categoryId,
                            orElse: () => Category(id: '', name: '(삭제됨)', type: 'expense'))
                        .name;
                return ListTile(title: Text(categoryName), trailing: Text('${b.amount}원'));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                DropdownButton<String?>(
                  value: _selectedCategoryId,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('전체 예산')),
                    ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
                  ],
                  onChanged: (v) => setState(() => _selectedCategoryId = v),
                ),
                Expanded(
                  child: TextField(
                    controller: _amountController,
                    decoration: const InputDecoration(labelText: '금액'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.check),
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
