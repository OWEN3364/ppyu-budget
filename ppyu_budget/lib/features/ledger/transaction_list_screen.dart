import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart';

class TransactionListScreen extends StatefulWidget {
  const TransactionListScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {
  List<LedgerTransaction>? _transactions;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final transactions = await transactionRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _transactions = transactions;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 내역을 불러오지 못했어요');
    }
  }

  @override
  Widget build(BuildContext context) {
    final transactions = _transactions;
    return Scaffold(
      appBar: AppBar(title: const Text('거래 내역')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TransactionFormScreen(householdId: widget.householdId),
          ));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
          : transactions == null
          ? const Center(child: CircularProgressIndicator())
          : transactions.isEmpty
              ? const Center(child: Text('아직 거래 내역이 없어요'))
              : ListView.builder(
                  itemCount: transactions.length,
                  itemBuilder: (context, i) {
                    final t = transactions[i];
                    final sign = t.type == 'expense' ? '-' : '+';
                    return ListTile(
                      title: Text('$sign${t.amount}원'),
                      subtitle: Text(t.memo ?? ''),
                    );
                  },
                ),
    );
  }
}
