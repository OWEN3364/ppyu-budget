import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/notification_capture/notification_capture_service.dart';
import 'package:ppyu_budget/features/notification_capture/notification_pending_screen.dart';
import 'package:ppyu_budget/features/notification_capture/notification_settings.dart';

final notificationCaptureService = NotificationCaptureService();

class NotificationOnboardingScreen extends StatefulWidget {
  const NotificationOnboardingScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<NotificationOnboardingScreen> createState() => _NotificationOnboardingScreenState();
}

class _NotificationOnboardingScreenState extends State<NotificationOnboardingScreen>
    with WidgetsBindingObserver {
  bool? _granted;
  bool? _confirmBeforeSave;
  // Task 6's NotificationCaptureService documents that openAccessSettings()
  // and isAccessGranted() must never overlap in time (the native side shares
  // one result callback across all plugin methods, so calling isAccessGranted()
  // while openAccessSettings() is still pending can make openAccessSettings()
  // hang forever). This guard stops the lifecycle-resume auto-refresh below
  // from racing a still-in-flight openAccessSettings() call.
  bool _openingSettings = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _loadSetting();
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
    try {
      final granted = await notificationCaptureService.isAccessGranted();
      if (!mounted) return;
      setState(() {
        _granted = granted;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '상태 확인에 실패했어요');
    }
  }

  Future<void> _loadSetting() async {
    final value = await notificationSettings.confirmBeforeSave();
    if (mounted) setState(() => _confirmBeforeSave = value);
  }

  Future<void> _openSettings() async {
    setState(() {
      _openingSettings = true;
      _error = null;
    });
    try {
      await notificationCaptureService.openAccessSettings();
    } catch (e) {
      if (mounted) setState(() => _error = '설정 화면을 여는 데 실패했어요');
    } finally {
      if (mounted) setState(() => _openingSettings = false);
    }
    // _refresh() clears _error on success — skip it when openAccessSettings()
    // just failed, so its error message isn't wiped before the user sees it
    // (the settings screen never opened, so there's nothing new to re-check).
    if (_error == null) await _refresh();
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
              '카드/은행 결제 알림이 뜰 때 자동으로 거래를 기록해주는 기능을 준비 중이에요.\n'
              '지금은 알림 접근 권한을 설정하는 단계예요. 아래 설정은 지금 바꿔두시면\n'
              '자동 기록이 연결되는 다음 업데이트부터 그대로 적용돼요.\n'
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 24),
            SwitchListTile(
              title: const Text('확인 후 저장'),
              subtitle: const Text('꺼두면 인식된 거래가 바로 저장돼요. 켜두면 확인 후 저장 목록에서 검토 후 저장돼요.'),
              value: _confirmBeforeSave ?? false,
              onChanged: _confirmBeforeSave == null
                  ? null
                  : (v) async {
                      setState(() => _confirmBeforeSave = v);
                      await notificationSettings.setConfirmBeforeSave(v);
                    },
            ),
            // Shown regardless of the toggle's VALUE: turning it off must not
            // strand rows that piled up while it was on. The pending screen
            // has its own empty state when there's nothing to review.
            if (_confirmBeforeSave != null)
              ElevatedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NotificationPendingScreen(householdId: widget.householdId),
                )),
                child: const Text('확인 후 저장 목록 보기'),
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
