import 'package:ppyu_budget/core/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/models/savings_goal.dart';
import 'package:ppyu_budget/features/ledger/savings_goal_repository.dart';

final savingsGoalRepository = SavingsGoalRepository(client: supabase);

class SavingsGoalScreen extends StatefulWidget {
  const SavingsGoalScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<SavingsGoalScreen> createState() => _SavingsGoalScreenState();
}

class _SavingsGoalScreenState extends State<SavingsGoalScreen> {
  final _nameController = TextEditingController();
  final _targetController = TextEditingController();
  List<SavingsGoal>? _goals;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final goals = await savingsGoalRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _goals = goals;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '저축 목표를 불러오지 못했어요');
    }
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    final target = int.tryParse(_targetController.text.trim());
    if (name.isEmpty || target == null || target <= 0) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await savingsGoalRepository.create(
        householdId: widget.householdId,
        name: name,
        targetAmount: target,
      );
      _nameController.clear();
      _targetController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '목표 추가에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final goals = _goals;
    return Scaffold(
      appBar: AppBar(title: const Text('저축 목표')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.error)),
          Expanded(
            child: goals == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: goals.length,
                    itemBuilder: (context, i) {
                      final g = goals[i];
                      final progress = g.targetAmount == 0 ? 0.0 : g.currentAmount / g.targetAmount;
                      return ListTile(
                        title: Text(g.name),
                        subtitle: LinearProgressIndicator(value: progress.clamp(0, 1)),
                        trailing: Text('${g.currentAmount}/${g.targetAmount}원'),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '목표 이름'),
                ),
                TextField(
                  controller: _targetController,
                  decoration: const InputDecoration(labelText: '목표 금액'),
                  keyboardType: TextInputType.number,
                ),
                ElevatedButton(onPressed: _saving ? null : _add, child: const Text('목표 추가')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
