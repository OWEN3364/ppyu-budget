import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';

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

  Future<void> _invite() async {
    setState(() => _creating = true);
    try {
      final householdId = await _repository.createHousehold();
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => InviteScreen(householdId: householdId),
        ));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_householdId != null) {
      return const Scaffold(
        body: Center(child: Text('배우자와 연동됐어요')),
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
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const JoinScreen()),
              ),
              child: const Text('초대 코드로 연동하기'),
            ),
          ],
        ),
      ),
    );
  }
}
