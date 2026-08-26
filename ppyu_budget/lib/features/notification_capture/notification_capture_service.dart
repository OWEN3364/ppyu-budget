import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart' as nls;

/// A single system notification, reduced to what the parser (Task 3) needs.
class RawNotification {
  const RawNotification({
    required this.packageName,
    required this.text,
    required this.id,
    required this.timestamp,
  });

  final String packageName;
  final String text;

  /// The platform notification id and post time, carried through unused for
  /// now so future duplicate-suppression work doesn't have to rework this
  /// interface. Nothing downstream reads them yet.
  final String id;
  final DateTime timestamp;
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
  ///
  /// Do not call this (or any other method on this service) while an
  /// [openAccessSettings] call is still pending. The native plugin shares a
  /// single pending-result slot across all method calls, so an overlapping
  /// call here can make the in-flight [openAccessSettings] future hang
  /// forever instead of completing when the settings result eventually
  /// arrives.
  Future<bool> isAccessGranted() => nls.NotificationListenerService.isPermissionGranted();

  /// Opens the system "notification access" settings screen where the user
  /// grants (or revokes) access for this app. The underlying call returns a
  /// bool once the user returns to the app, but callers of this wrapper
  /// re-check via [isAccessGranted] rather than trust that return value.
  ///
  /// Do not call any other method on this service while this Future is
  /// pending — the native side shares one result callback across all
  /// methods, and calling another method concurrently can cause this Future
  /// to hang forever (the eventual real result has nowhere valid to land).
  /// In particular, do not poll [isAccessGranted] (e.g. from an
  /// `AppLifecycleState.resumed` handler) until this Future has completed.
  Future<void> openAccessSettings() async {
    await nls.NotificationListenerService.requestPermission();
  }

  /// Every notification the listener observes system-wide, reduced to
  /// package name + text. Title and content are concatenated because
  /// `NotificationParser.parse` (Task 3) takes a single `text` string.
  ///
  /// Filters out two kinds of noise the native stream also emits:
  /// removal events (the plugin re-emits the same notification with
  /// `hasRemoved: true` when the user dismisses it, which would otherwise
  /// double-capture every real notification) and connection/disconnection
  /// broadcasts (emitted with an empty package name).
  Stream<RawNotification> get notifications => nls.NotificationListenerService.notificationsStream
      .where((event) => !event.hasRemoved && event.packageName.isNotEmpty)
      .map(_toRawNotification);

  RawNotification _toRawNotification(ServiceNotificationEvent event) {
    final title = event.title.trim();
    final content = event.content.trim();
    final text = [title, content].where((s) => s.isNotEmpty).join(' ');
    return RawNotification(
      packageName: event.packageName,
      text: text,
      id: event.id.toString(),
      // `humanTime` is the plugin's own DateTime view of its epoch-millis
      // `timestamp` field.
      timestamp: event.humanTime,
    );
  }
}
