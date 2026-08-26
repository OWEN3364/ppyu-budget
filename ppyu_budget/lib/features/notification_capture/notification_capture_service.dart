import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart' as nls;

/// A single system notification, reduced to what the parser (Task 3) needs.
class RawNotification {
  const RawNotification({required this.packageName, required this.text});

  final String packageName;
  final String text;
}

/// Wraps the `notification_listener_service` package behind a small,
/// package-agnostic interface so the rest of the app (Task 7) never needs to
/// know which underlying plugin reads Android's `NotificationListenerService`.
///
/// This only reads notification metadata (source package + text) — it never
/// touches SMS (`READ_SMS`/`RECEIVE_SMS`) and never requests that permission.
class NotificationCaptureService {
  /// Whether the user has already granted notification access in system
  /// settings (Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS access list).
  Future<bool> isAccessGranted() => nls.NotificationListenerService.isPermissionGranted();

  /// Opens the system "notification access" settings screen where the user
  /// grants (or revokes) access for this app. The underlying call returns a
  /// bool once the user returns to the app, but callers of this wrapper
  /// re-check via [isAccessGranted] rather than trust that return value.
  Future<void> openAccessSettings() async {
    await nls.NotificationListenerService.requestPermission();
  }

  /// Every notification the listener observes system-wide, reduced to
  /// package name + text. Title and content are concatenated because
  /// `NotificationParser.parse` (Task 3) takes a single `text` string.
  Stream<RawNotification> get notifications =>
      nls.NotificationListenerService.notificationsStream.map(_toRawNotification);

  RawNotification _toRawNotification(ServiceNotificationEvent event) {
    final title = event.title.trim();
    final content = event.content.trim();
    final text = [title, content].where((s) => s.isNotEmpty).join(' ');
    return RawNotification(packageName: event.packageName, text: text);
  }
}
