import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;

String? extractInviteCode(Uri link) => link.queryParameters['code'];

// Korean copy for the known error codes join_household() raises
// (see supabase/migrations/0001_household_schema.sql).
const _joinErrorMessages = {
  'invalid_or_expired_code': '코드가 만료되었거나 잘못됐어요',
  'household_full': '이미 정원(2명)이 다 찼어요',
  'already_member': '이미 연동된 사용자예요',
};

String _describeJoinError(Object e) {
  if (e is PostgrestException) {
    return _joinErrorMessages[e.message] ?? '연동 실패: 다시 시도해주세요';
  }
  return '연동 실패: 다시 시도해주세요';
}

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, this.prefillCode});

  final String? prefillCode;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  late final _controller = TextEditingController(text: widget.prefillCode);
  String? _error;
  bool _joining = false;

  Future<void> _join(String code) async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await householdRepository.joinHousehold(code);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _describeJoinError(e));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('배우자와 연동하기')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: '6자리 초대 코드'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _joining ? null : () => _join(_controller.text.trim()),
              child: const Text('코드로 연동'),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const Divider(height: 32),
            SizedBox(
              height: 250,
              child: MobileScanner(
                onDetect: (capture) {
                  // mobile_scanner can emit a capture with no barcodes; .first would throw.
                  if (capture.barcodes.isEmpty || _joining) return;
                  final value = capture.barcodes.first.rawValue;
                  if (value == null) return;
                  final code = extractInviteCode(Uri.parse(value));
                  if (code != null) _join(code);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
