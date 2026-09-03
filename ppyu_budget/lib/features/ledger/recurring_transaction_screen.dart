import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ads/ad_banner_widget.dart' show adBannerHeight;
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;
import 'package:ppyu_budget/features/ledger/account_screen.dart' show accountRepository;
import 'package:ppyu_budget/features/ledger/category_screen.dart' show categoryRepository;
import 'package:ppyu_budget/features/ledger/models/account.dart';
import 'package:ppyu_budget/features/ledger/models/category.dart';
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart' show recurringTransactionRepository;

class RecurringTransactionListScreen extends StatefulWidget {
  const RecurringTransactionListScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<RecurringTransactionListScreen> createState() => _RecurringTransactionListScreenState();
}

class _RecurringTransactionListScreenState extends State<RecurringTransactionListScreen> {
  List<RecurringTransaction>? _templates;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final templates = await recurringTransactionRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _templates = templates;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '반복거래를 불러오지 못했어요');
    }
  }

  String _ruleLabel(String rule) {
    if (rule == 'DAILY') return '매일';
    if (rule.startsWith('WEEKLY:')) return '매주';
    if (rule == 'MONTHLY') return '매월';
    if (rule == 'YEARLY') return '매년';
    return rule;
  }

  @override
  Widget build(BuildContext context) {
    final templates = _templates;
    return Scaffold(
      floatingActionButton: Padding(
        // 화면 하단 고정 광고 배너(전역 배선, 이 Scaffold는 모름) 위로 FAB를 밀어올림.
        padding: EdgeInsets.only(bottom: adBannerHeight),
        child: FloatingActionButton(
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RecurringTransactionFormScreen(householdId: widget.householdId),
            ));
            _load();
          },
          child: const Icon(Icons.add),
        ),
      ),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: templates == null
                ? const Center(child: CircularProgressIndicator())
                : templates.isEmpty
                    ? const Center(child: Text('등록된 반복거래가 없어요'))
                    : ListView.builder(
                        itemCount: templates.length,
                        itemBuilder: (context, i) {
                          final t = templates[i];
                          final sign = t.type == 'expense' ? '-' : '+';
                          return ListTile(
                            title: Text('$sign${t.amount}원 · ${_ruleLabel(t.intervalRule)}'),
                            subtitle: Text('시작일: ${t.startAt.year}-${t.startAt.month.toString().padLeft(2, '0')}-${t.startAt.day.toString().padLeft(2, '0')}'),
                            trailing: Chip(label: Text(t.autoRegister ? '자동' : '확인 후 등록')),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => RecurringTransactionFormScreen(
                                  householdId: widget.householdId,
                                  existing: t,
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

const _weekdayLabels = [
  ('MO', '월'), ('TU', '화'), ('WE', '수'), ('TH', '목'), ('FR', '금'), ('SA', '토'), ('SU', '일'),
];

enum _Frequency { daily, weekly, monthly, yearly }

class RecurringTransactionFormScreen extends StatefulWidget {
  const RecurringTransactionFormScreen({super.key, required this.householdId, this.existing});

  final String householdId;
  final RecurringTransaction? existing;

  @override
  State<RecurringTransactionFormScreen> createState() => _RecurringTransactionFormScreenState();
}

class _RecurringTransactionFormScreenState extends State<RecurringTransactionFormScreen> {
  late final _amountController = TextEditingController(text: widget.existing?.amount.toString() ?? '');
  late final _memoController = TextEditingController(text: widget.existing?.memo ?? '');
  late String _type = widget.existing?.type ?? 'expense';
  late DateTime _startAt = widget.existing?.startAt ?? DateTime.now();
  late bool _autoRegister = widget.existing?.autoRegister ?? false;
  late _Frequency _frequency = _parseFrequency(widget.existing?.intervalRule);
  late final Set<String> _selectedWeekdays = _parseWeekdays(widget.existing?.intervalRule);
  List<Account>? _accounts;
  List<Category>? _categories;
  String? _accountId;
  String? _categoryId;
  Map<String, String>? _nicknames;
  String? _ownerMemberId;
  String? _error;
  bool _saving = false;

  static _Frequency _parseFrequency(String? rule) {
    if (rule == 'DAILY') return _Frequency.daily;
    if (rule != null && rule.startsWith('WEEKLY:')) return _Frequency.weekly;
    if (rule == 'YEARLY') return _Frequency.yearly;
    return _Frequency.monthly;
  }

  static Set<String> _parseWeekdays(String? rule) {
    if (rule == null || !rule.startsWith('WEEKLY:')) return {};
    return rule.substring(7).split(',').toSet();
  }

  String get _intervalRule {
    switch (_frequency) {
      case _Frequency.daily:
        return 'DAILY';
      case _Frequency.weekly:
        return _selectedWeekdays.isEmpty ? 'DAILY' : 'WEEKLY:${_selectedWeekdays.join(',')}';
      case _Frequency.monthly:
        return 'MONTHLY';
      case _Frequency.yearly:
        return 'YEARLY';
    }
  }

  @override
  void initState() {
    super.initState();
    _accountId = widget.existing?.accountId;
    _categoryId = widget.existing?.categoryId;
    _ownerMemberId = widget.existing?.ownerMemberId;
    _loadOptions();
    _loadOwnerOptions();
  }

  Future<void> _loadOwnerOptions() async {
    try {
      final nicknames = await householdRepository.nicknamesByMemberId(widget.householdId);
      String? defaultOwner = _ownerMemberId;
      defaultOwner ??= await householdRepository.myMemberId(widget.householdId);
      if (!mounted) return;
      setState(() {
        _nicknames = nicknames;
        _ownerMemberId = nicknames.containsKey(defaultOwner) ? defaultOwner : (nicknames.isNotEmpty ? nicknames.keys.first : null);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '가구 구성원을 불러오지 못했어요');
    }
  }

  Future<void> _loadOptions() async {
    final requestedType = _type;
    try {
      final accounts = await accountRepository.list(widget.householdId);
      final categories = await categoryRepository.list(widget.householdId, type: _type);
      if (!mounted || requestedType != _type) return;
      setState(() {
        _accounts = accounts;
        _categories = categories;
        _accountId = accounts.any((a) => a.id == _accountId) ? _accountId : (accounts.isNotEmpty ? accounts.first.id : null);
        _categoryId = categories.any((c) => c.id == _categoryId) ? _categoryId : (categories.isNotEmpty ? categories.first.id : null);
        _error = null;
      });
    } catch (e) {
      if (!mounted || requestedType != _type) return;
      setState(() => _error = '계좌/카테고리를 불러오지 못했어요');
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _startAt = DateTime(picked.year, picked.month, picked.day, _startAt.hour, _startAt.minute));
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amountController.text.trim());
    final accountId = _accountId;
    final categoryId = _categoryId;
    final ownerMemberId = _ownerMemberId;
    if (amount == null || amount <= 0 || accountId == null || categoryId == null || ownerMemberId == null) {
      setState(() => _error = '금액, 계좌, 카테고리, 소유자를 확인해주세요');
      return;
    }
    if (_frequency == _Frequency.weekly && _selectedWeekdays.isEmpty) {
      setState(() => _error = '반복할 요일을 하나 이상 선택해주세요');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      final memo = _memoController.text.trim().isEmpty ? null : _memoController.text.trim();
      if (existing == null) {
        final myId = await householdRepository.myMemberId(widget.householdId);
        await recurringTransactionRepository.create(
          householdId: widget.householdId,
          accountId: accountId,
          categoryId: categoryId,
          createdBy: myId,
          ownerMemberId: ownerMemberId,
          type: _type,
          amount: amount,
          intervalRule: _intervalRule,
          startAt: _startAt,
          autoRegister: _autoRegister,
          memo: memo,
        );
      } else {
        // Changing the schedule of an auto-registering template shifts every
        // future occurrence onto dates that don't exist yet, so the next
        // catch-up run silently back-fills them — looks like a duplicate
        // charge to the user. The unique index can't catch this (the new
        // dates are genuinely new), so ask first.
        if (_autoRegister && (_startAt != existing.startAt || _intervalRule != existing.intervalRule)) {
          final proceed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('일정 변경 확인'),
              content: const Text('시작일이나 반복 주기를 바꾸면, 자동 등록 템플릿이 새 일정 기준으로 지난 거래를 다시 만들 수 있어요. 계속할까요?'),
              actions: [
                TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('취소')),
                TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('계속')),
              ],
            ),
          );
          if (proceed != true) return; // finally clears _saving
        }
        await recurringTransactionRepository.update(
          id: existing.id,
          accountId: accountId,
          categoryId: categoryId,
          ownerMemberId: ownerMemberId,
          type: _type,
          amount: amount,
          intervalRule: _intervalRule,
          startAt: _startAt,
          autoRegister: _autoRegister,
          memo: memo,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '반복거래 저장에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('반복거래 삭제'),
        content: const Text('템플릿만 삭제되고, 이미 생성된 과거 거래는 그대로 남아있어요. 삭제할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('삭제')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await recurringTransactionRepository.delete(existing.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '반복거래 삭제에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    final categories = _categories;
    final existing = widget.existing;
    if (accounts == null || categories == null) {
      return Scaffold(
        appBar: AppBar(title: Text(existing == null ? '반복거래 추가' : '반복거래 수정')),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
            : const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? '반복거래 추가' : '반복거래 수정'),
        actions: [
          if (existing != null)
            IconButton(icon: const Icon(Icons.delete), onPressed: _saving ? null : _delete),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            DropdownButton<String>(
              value: _type,
              items: const [
                DropdownMenuItem(value: 'expense', child: Text('지출')),
                DropdownMenuItem(value: 'income', child: Text('수입')),
              ],
              onChanged: (v) {
                setState(() => _type = v ?? 'expense');
                _loadOptions();
              },
            ),
            TextField(
              controller: _amountController,
              decoration: const InputDecoration(labelText: '금액'),
              keyboardType: TextInputType.number,
            ),
            if (accounts.isNotEmpty)
              DropdownButton<String>(
                value: _accountId,
                items: accounts.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name))).toList(),
                onChanged: (v) => setState(() => _accountId = v),
              ),
            if (categories.isNotEmpty)
              DropdownButton<String>(
                value: _categoryId,
                items: categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            TextField(
              controller: _memoController,
              decoration: const InputDecoration(labelText: '메모(선택)'),
            ),
            if (_nicknames != null && _nicknames!.isNotEmpty)
              DropdownButton<String>(
                value: _ownerMemberId,
                items: _nicknames!.entries.map((e) => DropdownMenuItem(value: e.key, child: Text('소유자: ${e.value}'))).toList(),
                onChanged: (v) => setState(() => _ownerMemberId = v),
              ),
            SwitchListTile(
              title: const Text('자동 등록'),
              subtitle: const Text('꺼두면 "처리할 목록"에서 확인 후 등록해요'),
              value: _autoRegister,
              onChanged: (v) => setState(() => _autoRegister = v),
            ),
            ListTile(
              title: const Text('시작일'),
              subtitle: Text('${_startAt.year}-${_startAt.month.toString().padLeft(2, '0')}-${_startAt.day.toString().padLeft(2, '0')}'),
              onTap: _pickDate,
            ),
            DropdownButton<_Frequency>(
              value: _frequency,
              items: const [
                DropdownMenuItem(value: _Frequency.daily, child: Text('매일')),
                DropdownMenuItem(value: _Frequency.weekly, child: Text('매주')),
                DropdownMenuItem(value: _Frequency.monthly, child: Text('매월')),
                DropdownMenuItem(value: _Frequency.yearly, child: Text('매년')),
              ],
              onChanged: (v) => setState(() => _frequency = v ?? _Frequency.monthly),
            ),
            if (_frequency == _Frequency.weekly)
              Wrap(
                spacing: 8,
                children: _weekdayLabels.map((entry) {
                  final (code, label) = entry;
                  final selected = _selectedWeekdays.contains(code);
                  return FilterChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedWeekdays.add(code);
                      } else {
                        _selectedWeekdays.remove(code);
                      }
                    }),
                  );
                }).toList(),
              ),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }
}
