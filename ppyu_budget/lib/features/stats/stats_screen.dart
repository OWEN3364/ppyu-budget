import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/tag_management_screen.dart' show tagRepository;
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
import 'package:ppyu_budget/features/stats/csv_export.dart';
import 'package:ppyu_budget/features/stats/models/category_summary.dart';
import 'package:ppyu_budget/features/stats/models/spending_recommendation.dart';
import 'package:ppyu_budget/features/stats/stats_repository.dart';

final statsRepository = StatsRepository(client: supabase);

const _chartColors = [
  Colors.blue, Colors.red, Colors.green, Colors.orange,
  Colors.purple, Colors.teal, Colors.brown, Colors.pink,
];

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  List<CategorySummary>? _summary;
  List<SpendingRecommendation>? _recommendations;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final requestedMonth = _month;
    try {
      final summary = await statsRepository.monthlyCategorySummary(widget.householdId, _month);
      final recommendations = await statsRepository.spendingRecommendations(widget.householdId, _month);
      if (!mounted || requestedMonth != _month) return;
      setState(() {
        _summary = summary;
        _recommendations = recommendations;
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestedMonth != _month) return;
      setState(() => _error = '통계를 불러오지 못했어요');
    }
  }

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta, 1);
      _summary = null;
      _recommendations = null;
    });
    _load();
  }

  bool _exporting = false;

  Future<void> _exportCsv() async {
    setState(() => _exporting = true);
    try {
      final allTransactions = await transactionRepository.list(widget.householdId, confirmed: true);
      final monthTransactions = allTransactions
          .where((t) =>
              t.occurredAt.toLocal().year == _month.year &&
              t.occurredAt.toLocal().month == _month.month)
          .toList();
      if (monthTransactions.isEmpty) {
        if (mounted) setState(() => _error = '내보낼 거래가 없어요');
        return;
      }
      final accounts = await accountRepository.list(widget.householdId);
      final categories = await categoryRepository.list(widget.householdId);
      final tags = await tagRepository.list(widget.householdId);
      final nicknames = await householdRepository.nicknamesByMemberId(widget.householdId);

      final csv = buildTransactionsCsv(
        transactions: monthTransactions,
        accountNames: {for (final a in accounts) a.id: a.name},
        categoryNames: {for (final c in categories) c.id: c.name},
        tagNames: {for (final t in tags) t.id: t.name},
        memberNicknames: nicknames,
      );

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(utf8.encode(csv), mimeType: 'text/csv')],
          fileNameOverrides: ['${_month.year}-${_month.month}-transactions.csv'],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'CSV 내보내기에 실패했어요');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final recommendations = _recommendations;
    final expenseCategories = summary?.where((s) => s.type == 'expense').toList() ?? [];

    return Scaffold(
      appBar: AppBar(title: const Text('통계')),
      body: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _changeMonth(-1)),
              Text('${_month.year}년 ${_month.month}월'),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _changeMonth(1)),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextButton.icon(
                onPressed: _exporting ? null : _exportCsv,
                icon: const Icon(Icons.share),
                label: const Text('CSV 내보내기'),
              ),
            ),
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          if (summary == null)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (expenseCategories.isEmpty)
            const Expanded(child: Center(child: Text('이번 달 기록된 거래가 없어요')))
          else ...[
            SizedBox(
              height: 240,
              child: PieChart(
                PieChartData(
                  sections: [
                    for (var i = 0; i < expenseCategories.length; i++)
                      PieChartSectionData(
                        value: expenseCategories[i].totalAmount.toDouble(),
                        title: expenseCategories[i].categoryName,
                        color: _chartColors[i % _chartColors.length],
                      ),
                  ],
                ),
              ),
            ),
            if (recommendations != null && recommendations.isNotEmpty)
              Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('소비 절감 추천', style: TextStyle(fontWeight: FontWeight.bold)),
                      for (final r in recommendations)
                        Text('${r.categoryName} 지출이 전월 대비 ${r.changeRatio.toStringAsFixed(0)}% 늘었어요'),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
