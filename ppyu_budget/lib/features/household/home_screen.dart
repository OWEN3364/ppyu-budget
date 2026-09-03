import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/calendar/calendar_screen.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';
import 'package:ppyu_budget/features/ledger/account_screen.dart';
import 'package:ppyu_budget/features/ledger/budget_screen.dart';
import 'package:ppyu_budget/features/ledger/category_screen.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_catchup_service.dart' show recurringTransactionCatchUpService;
import 'package:ppyu_budget/features/household/auto_registration_menu_screen.dart';
import 'package:ppyu_budget/features/ledger/savings_goal_screen.dart';
import 'package:ppyu_budget/features/ledger/tag_management_screen.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;
import 'package:ppyu_budget/features/ledger/transaction_list_screen.dart';
import 'package:ppyu_budget/features/notification_capture/notification_auto_save_service.dart';
import 'package:ppyu_budget/features/notification_capture/notification_onboarding_screen.dart' show notificationCaptureService;
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

  // Owned by the State, not by _setNickname: showDialog's future resolves at
  // Navigator.pop, before the closing animation ends, so a locally-disposed
  // controller could outlive its TextField mid-transition.
  final _nicknameController = TextEditingController();

  bool _loading = true;
  bool _creating = false;
  bool _settingNickname = false;
  String? _householdId;
  String? _error;
  Future<List<SpendingRecommendation>>? _recommendationsFuture;
  NotificationAutoSaveService? _notificationAutoSaveService;

  @override
  void initState() {
    super.initState();
    _loadHousehold();
  }

  @override
  void dispose() {
    _notificationAutoSaveService?.stop();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _loadHousehold() async {
    final householdId = await _repository.getMyHousehold();
    if (!mounted) return;
    setState(() {
      _householdId = householdId;
      _loading = false;
      _recommendationsFuture = householdId != null ? _fetchRecommendations(householdId) : null;
    });
    if (householdId != null) {
      _runCatchUp(householdId);
      _startNotificationAutoSave(householdId);
    }
  }

  Future<void> _runCatchUp(String householdId) async {
    try {
      final count = await recurringTransactionCatchUpService.run(householdId);
      if (!mounted || count == 0) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count건의 반복거래가 등록됐어요')),
      );
    } catch (_) {
      // 조용히 무시 — 다음 홈 화면 진입 때 다시 시도된다.
    }
  }

  // _loadHousehold()가 초대/합류 이후 재호출될 수 있으므로, 이미 시작된
  // 서비스가 있으면 다시 만들지 않는다 — 그렇지 않으면 알림마다 두 번씩
  // 처리(중복 거래 생성)될 수 있다.
  Future<void> _startNotificationAutoSave(String householdId) async {
    if (_notificationAutoSaveService != null) return;
    try {
      final granted = await notificationCaptureService.isAccessGranted();
      if (!granted || !mounted) return;
      final memberId = await householdRepository.myMemberId(householdId);
      if (!mounted) return;
      _notificationAutoSaveService = NotificationAutoSaveService(
        notifications: notificationCaptureService.notifications,
        householdId: householdId,
        memberId: memberId,
        accountRepository: accountRepository,
        categoryRepository: categoryRepository,
        transactionRepository: transactionRepository,
      )..start();
    } catch (_) {
      // 조용히 무시 — 다음 홈 화면 진입 때 다시 시도된다 (권한이 아직
      // 없는 게 정상 상태이므로 사용자에게 에러를 보여줄 필요는 없다).
    }
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
    _nicknameController.clear();
    final nickname = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('닉네임 설정'),
        content: TextField(controller: _nicknameController, decoration: const InputDecoration(labelText: '닉네임')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(_nicknameController.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (nickname == null || nickname.isEmpty || !mounted) return;
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
              title: const Text('캘린더'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CalendarScreen(householdId: householdId),
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
              title: const Text('자동거래등록'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AutoRegistrationMenuScreen(householdId: householdId),
              )),
            ),
            ListTile(
              title: const Text('저축 목표'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SavingsGoalScreen(householdId: householdId),
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
