import 'package:shared_preferences/shared_preferences.dart';

/// Локальный признак guest-сессии (дополняет is_guest с API).
abstract final class GuestSessionStorage {
  static const _key = 'familychat_guest_session_v1';

  static Future<void> markActive() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<bool> isActiveGuestSession() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }
}
