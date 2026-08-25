import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _creating = false;

  Future<void> _invite() async {
    setState(() => _creating = true);
    try {
      final householdId = await householdRepository.createHousehold();
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
