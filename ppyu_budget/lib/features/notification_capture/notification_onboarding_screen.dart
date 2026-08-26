import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/notification_capture/notification_capture_service.dart';

final notificationCaptureService = NotificationCaptureService();

class NotificationOnboardingScreen extends StatefulWidget {
  const NotificationOnboardingScreen({super.key});

  @override
  State<NotificationOnboardingScreen> createState() => _NotificationOnboardingScreenState();
}

class _NotificationOnboardingScreenState extends State<NotificationOnboardingScreen>
    with WidgetsBindingObserver {
  bool? _granted;
  // Task 6's NotificationCaptureService documents that openAccessSettings()
  // and isAccessGranted() must never overlap in time (the native side shares
  // one result callback across all plugin methods, so calling isAccessGranted()
  // while openAccessSettings() is still pending can make openAccessSettings()
  // hang forever). This guard stops the lifecycle-resume auto-refresh below
  // from racing a still-in-flight openAccessSettings() call.
  bool _openingSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // catches the user coming back from the system settings screen
    if (state == AppLifecycleState.resumed && !_openingSettings) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await notificationCaptureService.isAccessGranted();
    if (!mounted) return;
    setState(() => _granted = granted);
  }

  Future<void> _openSettings() async {
    setState(() => _openingSettings = true);
    await notificationCaptureService.openAccessSettings();
    _openingSettings = false;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('결제 알림 자동인식')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '카드/은행 결제 알림이 뜰 때 자동으로 거래를 기록해줘요.\n'
              'SMS가 아니라 "알림"을 읽는 방식이라 문자 읽기 권한은 필요 없어요.',
            ),
            const SizedBox(height: 16),
            Text(
              _granted == null
                  ? '상태 확인 중...'
                  : _granted!
                      ? '✅ 알림 접근이 허용되어 있어요.'
                      : '❌ 아직 알림 접근이 허용되지 않았어요.',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _openingSettings ? null : _openSettings,
              child: const Text('알림 접근 설정 열기'),
            ),
            const SizedBox(height: 24),
            const Text(
              '⚠️ 꼭 확인해주세요',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text(
              '위 설정을 켜도, 사용하시는 은행/카드 앱 자체의 알림이 꺼져있으면 자동인식이 안 돼요.\n'
              '휴대폰 설정 > 앱 > (은행/카드 앱 이름) > 알림에서 결제 알림을 켜주세요.\n'
              '삼성페이를 쓰신다면 삼성페이 알림도 켜주셔야 인식돼요.',
            ),
          ],
        ),
      ),
    );
  }
}
