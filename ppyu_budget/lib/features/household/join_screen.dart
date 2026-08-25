import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;

String? extractInviteCode(Uri link) => link.queryParameters['code'];

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
      setState(() => _error = '연동 실패: ${e.toString()}');
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
                  final value = capture.barcodes.first.rawValue;
                  if (value == null || _joining) return;
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
