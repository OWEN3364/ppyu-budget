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
import 'package:ppyu_budget/features/stats/models/spending_recommendation.dart';
import 'package:ppyu_budget/features/stats/stats_screen.dart' show StatsScreen, statsRepository;

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
  bool _settingNickname = false;
  String? _householdId;
  String? _error;
  Future<List<SpendingRecommendation>>? _recommendationsFuture;

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
      _recommendationsFuture = householdId != null ? _fetchRecommendations(householdId) : null;
    });
  }

  // Swallows failures (including a synchronous throw from the statsRepository
  // singleton itself, e.g. Supabase not yet initialized — as in widget tests
  // that fake out HouseholdRepository but never call Supabase.initialize())
  // into an empty list rather than an errored Future. FutureBuilder already
  // hides the card when the list is empty, and this avoids returning an
  // already-failed Future for a widget that may not have mounted yet to
  // attach an error handler.
  Future<List<SpendingRecommendation>> _fetchRecommendations(String householdId) async {
    try {
      return await statsRepository.spendingRecommendations(householdId, DateTime.now());
    } catch (_) {
      return const [];
    }
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
    controller.dispose();
    if (nickname == null || nickname.isEmpty) return;
    setState(() => _settingNickname = true);
    try {
      await _repository.setMyNickname(householdId, nickname);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('닉네임 저장에 실패했어요')),
        );
      }
    } finally {
      if (mounted) setState(() => _settingNickname = false);
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
            FutureBuilder<List<SpendingRecommendation>>(
              future: _recommendationsFuture,
              builder: (context, snapshot) {
                final recs = snapshot.data;
                if (recs == null || recs.isEmpty) return const SizedBox.shrink();
                return Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('${recs.first.categoryName} 지출이 전월 대비 ${recs.first.changeRatio.toStringAsFixed(0)}% 늘었어요'),
                  ),
                );
              },
            ),
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
              title: const Text('통계'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => StatsScreen(householdId: householdId),
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
              onTap: _settingNickname ? null : () => _setNickname(householdId),
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
