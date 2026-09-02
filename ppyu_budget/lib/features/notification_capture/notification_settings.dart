import 'package:shared_preferences/shared_preferences.dart';

/// Per-device setting (never synced through Supabase — a notification only
/// ever arrives on one spouse's phone, so this has no shared meaning across
/// the household). Controls whether NotificationAutoSaveService creates a
/// captured transaction already confirmed, or pending review.
class NotificationSettings {
  static const _key = 'notification_confirm_before_save';

  Future<bool> confirmBeforeSave() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> setConfirmBeforeSave(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final notificationSettings = NotificationSettings();
