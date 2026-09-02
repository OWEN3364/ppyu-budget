import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_home_screen.dart';
import 'package:ppyu_budget/features/notification_capture/notification_onboarding_screen.dart';

class AutoRegistrationMenuScreen extends StatelessWidget {
  const AutoRegistrationMenuScreen({super.key, required this.householdId});

  final String householdId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('자동거래등록')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('반복거래'),
            subtitle: const Text('정기 결제/수입을 템플릿으로 등록하고 처리해요'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RecurringTransactionHomeScreen(householdId: householdId),
            )),
          ),
          ListTile(
            title: const Text('자동인식 거래'),
            subtitle: const Text('카드/은행 결제 알림을 자동으로 인식해요'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const NotificationOnboardingScreen(),
            )),
          ),
        ],
      ),
    );
  }
}
