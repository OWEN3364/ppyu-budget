import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart' show recurringTransactionRepository;
import 'package:ppyu_budget/features/ledger/recurring_transaction_schedule.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;

class TodoItem {
  const TodoItem({required this.template, required this.occurrenceDate});
  final RecurringTransaction template;
  final DateTime occurrenceDate;
}

/// Pure so it can be unit-tested without a widget harness. Splits every
/// missing occurrence across [templates] (`auto_register=false` only) into
/// "mine" (owner is [myMemberId]) vs "spouse" (any other owner).
({List<TodoItem> mine, List<TodoItem> spouse}) splitTodoItems(
  List<RecurringTransaction> templates,
  String myMemberId, {
  required DateTime now,
  required Map<String, Set<DateTime>> existingOccurredAtByTemplateId,
}) {
  final mine = <TodoItem>[];
  final spouse = <TodoItem>[];
  for (final template in templates.where((t) => !t.autoRegister)) {
    final existing = existingOccurredAtByTemplateId[template.id] ?? const <DateTime>{};
    final missing = missingOccurrences(template, now: now, existingOccurredAt: existing);
    final bucket = template.ownerMemberId == myMemberId ? mine : spouse;
    bucket.addAll(missing.map((date) => TodoItem(template: template, occurrenceDate: date)));
  }
  return (mine: mine, spouse: spouse);
}

String _dateLabel(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Body content for the "처리할 목록" tab of the recurring-transaction home
/// screen (Task 8) — no own Scaffold/AppBar, embedded in a TabBarView.
class RecurringTransactionTodoScreen extends StatefulWidget {
  const RecurringTransactionTodoScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<RecurringTransactionTodoScreen> createState() => _RecurringTransactionTodoScreenState();
}

class _RecurringTransactionTodoScreenState extends State<RecurringTransactionTodoScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 2, vsync: this);
  List<TodoItem>? _mine;
  List<TodoItem>? _spouse;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final myMemberId = await householdRepository.myMemberId(widget.householdId);
      final templates = await recurringTransactionRepository.list(widget.householdId);
      final existingByTemplateId = <String, Set<DateTime>>{};
      for (final template in templates.where((t) => !t.autoRegister)) {
        existingByTemplateId[template.id] =
            await transactionRepository.occurredAtsForRecurringTransaction(template.id);
      }
      if (!mounted) return;
      final split = splitTodoItems(
        templates,
        myMemberId,
        now: DateTime.now(),
        existingOccurredAtByTemplateId: existingByTemplateId,
      );
      setState(() {
        _mine = split.mine;
        _spouse = split.spouse;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '처리할 목록을 불러오지 못했어요';
        _mine = const [];
        _spouse = const [];
      });
    }
  }

  Future<void> _confirm(TodoItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('거래 등록'),
        content: Text('${_dateLabel(item.occurrenceDate)}에 ${item.template.amount}원을 등록할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('등록')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await transactionRepository.create(
        householdId: widget.householdId,
        accountId: item.template.accountId,
        categoryId: item.template.categoryId,
        memberId: item.template.ownerMemberId,
        type: item.template.type,
        amount: item.template.amount,
        memo: item.template.memo,
        source: 'recurring_auto',
        occurredAt: item.occurrenceDate,
        recurringTransactionId: item.template.id,
      );
    } on PostgrestException catch (e) {
      // 23505 — 배우자가 먼저 처리한 경우: 에러 없이 목록만 새로고침하면 됨
      if (e.code != '23505') {
        if (mounted) setState(() => _error = '등록에 실패했어요');
        return;
      }
    } catch (e) {
      if (mounted) setState(() => _error = '등록에 실패했어요');
      return;
    }
    await _load();
  }

  Widget _list(List<TodoItem>? items) {
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return const Center(child: Text('처리할 항목이 없어요'));
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final sign = item.template.type == 'expense' ? '-' : '+';
        return ListTile(
          title: Text('$sign${item.template.amount}원 · ${_dateLabel(item.occurrenceDate)}'),
          subtitle: item.template.memo != null ? Text(item.template.memo!) : null,
          onTap: () => _confirm(item),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(controller: _tabController, tabs: const [Tab(text: '나'), Tab(text: '배우자')]),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: TabBarView(controller: _tabController, children: [_list(_mine), _list(_spouse)]),
        ),
      ],
    );
  }
}
