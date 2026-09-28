import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local links between FamilyChat server folders and Telegram folders,
/// plus FC-only members attached to a Telegram folder tab.
abstract final class ChatHubFolderMirrorStore {
  static const _fcToTgKey = 'familychat_folder_fc_to_tg_v1';
  static const _tgExtrasKey = 'familychat_folder_tg_fc_extras_v1';

  /// FC folder id → TG chat_folder id.
  static Future<Map<int, int>> loadFcToTg() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeIntMap(prefs.getString(_fcToTgKey));
  }

  static Future<void> saveFcToTg(Map<int, int> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fcToTgKey, jsonEncode({
      for (final e in map.entries) '${e.key}': e.value,
    }));
  }

  static Future<void> link({
    required int fcFolderId,
    required int tgFolderId,
  }) async {
    final map = await loadFcToTg();
    map[fcFolderId] = tgFolderId;
    await saveFcToTg(map);
  }

  static Future<void> unlinkFc(int fcFolderId) async {
    final map = await loadFcToTg();
    if (map.remove(fcFolderId) == null) return;
    await saveFcToTg(map);
  }

  static Future<void> unlinkTg(int tgFolderId) async {
    final map = await loadFcToTg();
    final keys = map.entries
        .where((e) => e.value == tgFolderId)
        .map((e) => e.key)
        .toList();
    if (keys.isEmpty) return;
    for (final k in keys) {
      map.remove(k);
    }
    await saveFcToTg(map);
  }

  /// TG folder id → membership keys (`t:123`) for FC-only chats.
  static Future<Map<int, Set<String>>> loadTgExtras() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tgExtrasKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <int, Set<String>>{};
      for (final e in decoded.entries) {
        final id = int.tryParse('${e.key}');
        if (id == null) continue;
        final list = e.value;
        if (list is! List) continue;
        out[id] = {
          for (final v in list)
            if (v != null && '$v'.isNotEmpty) '$v',
        };
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveTgExtras(Map<int, Set<String>> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tgExtrasKey,
      jsonEncode({
        for (final e in map.entries) '${e.key}': e.value.toList(),
      }),
    );
  }

  static Future<void> addTgExtra({
    required int tgFolderId,
    required String memberKey,
  }) async {
    final map = await loadTgExtras();
    final set = map.putIfAbsent(tgFolderId, () => <String>{});
    if (!set.add(memberKey)) return;
    await saveTgExtras(map);
  }

  static Future<void> removeTgExtra({
    required int tgFolderId,
    required String memberKey,
  }) async {
    final map = await loadTgExtras();
    final set = map[tgFolderId];
    if (set == null || !set.remove(memberKey)) return;
    if (set.isEmpty) map.remove(tgFolderId);
    await saveTgExtras(map);
  }

  static Future<void> clearTgExtras(int tgFolderId) async {
    final map = await loadTgExtras();
    if (map.remove(tgFolderId) == null) return;
    await saveTgExtras(map);
  }

  static Map<int, int> _decodeIntMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <int, int>{};
      for (final e in decoded.entries) {
        final k = int.tryParse('${e.key}');
        final v = e.value is int
            ? e.value as int
            : int.tryParse('${e.value}');
        if (k != null && v != null) out[k] = v;
      }
      return out;
    } catch (_) {
      return {};
    }
  }
}
