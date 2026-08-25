import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () async {
                final householdId = await householdRepository.createHousehold();
                if (context.mounted) {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => InviteScreen(householdId: householdId),
                  ));
                }
              },
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
