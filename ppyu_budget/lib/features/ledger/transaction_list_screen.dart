import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
import 'package:ppyu_budget/features/ledger/models/tag.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/tag_management_screen.dart' show tagRepository;
import 'package:ppyu_budget/features/ledger/transaction_detail_screen.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart';

/// Pure so it can be unit-tested without a widget harness. [query] is expected
/// already trimmed and lowercased; tag filtering is OR (any selected tag hits).
List<LedgerTransaction> filterTransactions(
  List<LedgerTransaction> all,
  String query,
  Set<String> selectedTagIds,
) {
  return all.where((t) {
    if (query.isNotEmpty) {
      final haystack = '${t.memo ?? ''} ${t.merchant ?? ''}'.toLowerCase();
      if (!haystack.contains(query)) return false;
    }
    if (selectedTagIds.isNotEmpty && !t.tagIds.any(selectedTagIds.contains)) {
      return false;
    }
    return true;
  }).toList();
}

class TransactionListScreen extends StatefulWidget {
  const TransactionListScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<TransactionListScreen> createState() => _TransactionListScreenState();
}

class _TransactionListScreenState extends State<TransactionListScreen> {
  List<LedgerTransaction>? _transactions;
  List<Tag>? _tags;
  Map<String, String> _nicknames = {};
  String? _error;
  final _searchController = TextEditingController();
  String _query = '';
  final Set<String> _selectedTagIds = {};

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  Future<void> _load() async {
    try {
      final transactions = await transactionRepository.list(widget.householdId);
      final tags = await tagRepository.list(widget.householdId);
      final nicknames = await householdRepository.nicknamesByMemberId(widget.householdId);
      if (!mounted) return;
      setState(() {
        _transactions = transactions;
        _tags = tags;
        _nicknames = nicknames;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '거래 내역을 불러오지 못했어요');
    }
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$mm/$dd $hh:$min';
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transactions = _transactions;
    final tags = _tags;
    final filtered = transactions == null
        ? null
        : filterTransactions(transactions, _query, _selectedTagIds);
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
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(labelText: '메모/사용처 검색', prefixIcon: Icon(Icons.search)),
            ),
          ),
          if (tags != null && tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                spacing: 8,
                children: tags.map((tag) {
                  final selected = _selectedTagIds.contains(tag.id);
                  return FilterChip(
                    label: Text(tag.name),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedTagIds.add(tag.id);
                      } else {
                        _selectedTagIds.remove(tag.id);
                      }
                    }),
                  );
                }).toList(),
              ),
            ),
          Expanded(
            child: filtered == null
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(child: Text('조건에 맞는 거래가 없어요'))
                    : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final t = filtered[i];
                        final sign = t.type == 'expense' ? '-' : '+';
                        return ListTile(
                          leading: t.source == 'notification_auto'
                              ? const Icon(Icons.notifications_active, size: 20)
                              : null,
                          title: Text(t.merchant?.isNotEmpty == true ? t.merchant! : (t.memo ?? '(내용 없음)')),
                          subtitle: Text('${_formatDate(t.occurredAt)} · ${_nicknames[t.memberId] ?? '가족 구성원'}'),
                          trailing: Text('$sign${t.amount}원'),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => TransactionDetailScreen(
                                householdId: widget.householdId,
                                transaction: t,
                              ),
                            ));
                            _load();
                          },
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}
