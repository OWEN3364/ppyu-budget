import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';

final householdRepository = HouseholdRepository(client: supabase);

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  String? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    try {
      final code = await householdRepository.createInviteCode(widget.householdId);
      if (!mounted) return;
      setState(() => _code = code);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '초대 코드 생성 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final link = code == null ? null : 'ppyubudget://invite?code=$code';
    return Scaffold(
      appBar: AppBar(title: const Text('배우자 초대')),
      body: Center(
        child: _error != null
            ? Text(_error!)
            : code == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(code, style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 16),
                      QrImageView(data: link!, size: 200),
                      const SizedBox(height: 16),
                      const Text('10분 안에 사용해야 합니다'),
                    ],
                  ),
      ),
    );
  }
}
