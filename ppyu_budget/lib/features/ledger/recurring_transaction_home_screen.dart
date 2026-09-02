import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_screen.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_todo_screen.dart';

class RecurringTransactionHomeScreen extends StatefulWidget {
  const RecurringTransactionHomeScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<RecurringTransactionHomeScreen> createState() => _RecurringTransactionHomeScreenState();
}

class _RecurringTransactionHomeScreenState extends State<RecurringTransactionHomeScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('반복거래'),
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: '처리할 목록'), Tab(text: '템플릿 관리')]),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          RecurringTransactionTodoScreen(householdId: widget.householdId),
          RecurringTransactionListScreen(householdId: widget.householdId),
        ],
      ),
    );
  }
}
