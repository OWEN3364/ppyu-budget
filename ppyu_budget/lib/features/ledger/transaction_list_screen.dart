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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final transactions = await transactionRepository.list(widget.householdId);
    if (!mounted) return;
    setState(() => _transactions = transactions);
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
      body: transactions == null
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
