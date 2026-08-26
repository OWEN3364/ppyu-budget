import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';

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
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('거래 상세')),
      body: Center(child: Text('${widget.transaction.amount}원')),
    );
  }
}
