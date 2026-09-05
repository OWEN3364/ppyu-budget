import 'package:ppyu_budget/core/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;

class NotificationPendingScreen extends StatefulWidget {
  const NotificationPendingScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<NotificationPendingScreen> createState() => _NotificationPendingScreenState();
}

class _NotificationPendingScreenState extends State<NotificationPendingScreen> {
  List<LedgerTransaction>? _pending;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pending = await transactionRepository.list(widget.householdId, confirmed: false);
      if (!mounted) return;
      setState(() {
        _pending = pending;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '확인할 목록을 불러오지 못했어요');
    }
  }

  Future<void> _confirm(LedgerTransaction t) async {
    try {
      await transactionRepository.confirm(t.id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '확인 처리에 실패했어요');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      appBar: AppBar(title: const Text('자동인식 거래 확인')),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.error)),
          Expanded(
            child: pending == null
                ? const Center(child: CircularProgressIndicator())
                : pending.isEmpty
                    ? const Center(child: Text('확인할 거래가 없어요'))
                    : ListView.builder(
                        itemCount: pending.length,
                        itemBuilder: (context, i) {
                          final t = pending[i];
                          final sign = t.type == 'expense' ? '-' : '+';
                          return ListTile(
                            title: Text('$sign${t.amount}원${t.merchant != null ? ' · ${t.merchant}' : ''}'),
                            trailing: TextButton(onPressed: () => _confirm(t), child: const Text('확인')),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
