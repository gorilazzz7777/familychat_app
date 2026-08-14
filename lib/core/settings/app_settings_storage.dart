import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

const _prefsKey = 'familychat_app_settings_v1';

class AppSettingsStorage {
  static Future<FamilyChatAppSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return const FamilyChatAppSettings();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return FamilyChatAppSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return FamilyChatAppSettings.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {}
    return const FamilyChatAppSettings();
  }

  static Future<void> save(FamilyChatAppSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(settings.toCacheJson()));
    } catch (_) {}
  }
}
