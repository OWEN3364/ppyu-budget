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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final goals = await savingsGoalRepository.list(widget.householdId);
    if (!mounted) return;
    setState(() => _goals = goals);
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    final target = int.tryParse(_targetController.text.trim());
    if (name.isEmpty || target == null || target <= 0) return;
    await savingsGoalRepository.create(
      householdId: widget.householdId,
      name: name,
      targetAmount: target,
    );
    _nameController.clear();
    _targetController.clear();
    _load();
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
                ElevatedButton(onPressed: _add, child: const Text('목표 추가')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
