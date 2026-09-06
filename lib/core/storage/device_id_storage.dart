import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Стабильный идентификатор устройства для гостевого входа.
class DeviceIdStorage {
  static const _key = 'familychat_device_id';

  static Future<String?> peek() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_key);
    if (existing != null && existing.length >= 8) return existing;
    return null;
  }

  static Future<bool> hasDeviceId() async => (await peek()) != null;

  static Future<String> getOrCreate() async {
    final existing = await peek();
    if (existing != null) return existing;
    return regenerate();
  }

  /// Новый device_id (после выхода из привязанного соц-аккаунта).
  static Future<String> regenerate() async {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    final id = List.generate(32, (_) => chars[r.nextInt(chars.length)]).join();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, id);
    return id;
  }
}
