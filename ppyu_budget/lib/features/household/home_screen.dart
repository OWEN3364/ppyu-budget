import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart';
import 'package:ppyu_budget/features/ledger/budget_screen.dart';
import 'package:ppyu_budget/features/ledger/category_screen.dart';
import 'package:ppyu_budget/features/ledger/savings_goal_screen.dart';
import 'package:ppyu_budget/features/ledger/tag_management_screen.dart';
import 'package:ppyu_budget/features/ledger/transaction_list_screen.dart';
import 'package:ppyu_budget/features/notification_capture/notification_onboarding_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, HouseholdRepository? repository})
      : _repository = repository;

  final HouseholdRepository? _repository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HouseholdRepository _repository =
      widget._repository ?? householdRepository;

  bool _loading = true;
  bool _creating = false;
  String? _householdId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHousehold();
  }

  Future<void> _loadHousehold() async {
    final householdId = await _repository.getMyHousehold();
    if (!mounted) return;
    setState(() {
      _householdId = householdId;
      _loading = false;
    });
  }

  Future<void> _setNickname(String householdId) async {
    final controller = TextEditingController();
    final nickname = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('닉네임 설정'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: '닉네임')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (nickname == null || nickname.isEmpty) return;
    try {
      await _repository.setMyNickname(householdId, nickname);
    } catch (e) {
      if (mounted) setState(() => _error = '닉네임 저장에 실패했어요');
    }
  }

  Future<void> _invite() async {
    setState(() => _creating = true);
    try {
      final householdId = await _repository.createHousehold();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InviteScreen(householdId: householdId),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = '초대 생성에 실패했어요');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
    await _loadHousehold();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_householdId != null) {
      final householdId = _householdId!;
      return Scaffold(
        appBar: AppBar(title: const Text('쀼가계부')),
        body: ListView(
          children: [
            ListTile(
              title: const Text('배우자 초대'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => InviteScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('거래 내역'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TransactionListScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('계좌/카드 관리'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AccountScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('카테고리 관리'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CategoryScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('태그 관리'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TagManagementScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('닉네임 설정'),
              onTap: () => _setNickname(householdId),
            ),
            ListTile(
              title: const Text('이번 달 예산'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => BudgetScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('저축 목표'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SavingsGoalScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('결제 알림 자동인식 설정'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NotificationOnboardingScreen(),
              )),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: _creating ? null : _invite,
              child: const Text('배우자 초대하기'),
            ),
            ElevatedButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const JoinScreen()),
                );
                _loadHousehold();
              },
              child: const Text('초대 코드로 연동하기'),
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
],
        ),
      ),
    );
  }
}
