import 'package:shared_preferences/shared_preferences.dart';

/// Локально закреплённые чаты хаба (порядок = сверху вниз).
abstract final class ChatHubPinStorage {
  static const _key = 'familychat_chat_hub_pinned_v1';

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Future<void> save(List<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    if (keys.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(_key, keys.join(','));
  }
}
