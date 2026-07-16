import 'package:shared_preferences/shared_preferences.dart';

/// Порядок вкладок фильтра чатов (Все / Семья / …).
abstract final class ChatHubTabOrderStorage {
  static const _key = 'familychat_chat_hub_tab_order';

  static Future<List<String>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return null;
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Future<void> save(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, order.join(','));
  }
}
