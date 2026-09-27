import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local map: Telegram user id → FamilyChat contact identity.
class TelegramMatchStore {
  TelegramMatchStore._();
  static final instance = TelegramMatchStore._();

  static const _key = 'tdlib_tg_fc_matches_v1';

  /// Bumps when matches are saved/imported so UI can reload.
  final ValueNotifier<int> revision = ValueNotifier(0);

  Future<Map<int, TelegramMatch>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final out = <int, TelegramMatch>{};
      for (final e in map.entries) {
        final tgId = int.tryParse(e.key);
        if (tgId == null || e.value is! Map) continue;
        final m = Map<String, dynamic>.from(e.value as Map);
        out[tgId] = TelegramMatch.fromJson(m);
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> save(TelegramMatch match) async {
    final all = await loadAll();
    all[match.tgUserId] = match;
    await _persist(all);
  }

  Future<void> remove(int tgUserId) async {
    final all = await loadAll();
    all.remove(tgUserId);
    await _persist(all);
  }

  Future<TelegramMatch?> get(int tgUserId) async {
    final all = await loadAll();
    return all[tgUserId];
  }

  /// Import FC↔TG links from secretary `telegram/chats/` payload.
  /// Only fills missing private matches (does not overwrite local links).
  Future<int> importFromSecretaryChats(List<Map<String, dynamic>> chats) async {
    if (chats.isEmpty) return 0;
    final all = await loadAll();
    var added = 0;
    for (final c in chats) {
      if (c['is_private'] != true) continue;
      final matchedUserId = (c['matched_user_id'] as num?)?.toInt();
      final tgChatId = (c['tg_chat_id'] as num?)?.toInt();
      if (matchedUserId == null || matchedUserId <= 0) continue;
      if (tgChatId == null || tgChatId <= 0) continue;
      // Private Bot/TDLib chat id == peer user id.
      if (all.containsKey(tgChatId)) continue;
      final title = (c['title'] ?? c['tg_title'] ?? c['default_title'] ?? '')
          .toString()
          .trim();
      final avatar = (c['peer_avatar_url'] ?? c['photo_url'] ?? '')
          .toString()
          .trim();
      all[tgChatId] = TelegramMatch(
        tgUserId: tgChatId,
        tgChatId: tgChatId,
        fcUserId: matchedUserId,
        displayName: title.isNotEmpty ? title : 'Telegram',
        avatarUrl: avatar,
        fromSecretary: true,
      );
      added++;
    }
    if (added > 0) await _persist(all);
    return added;
  }

  /// Sync hub matches from server family TDLib identities + local private chats.
  ///
  /// [privateTgUserToChatId] maps peer `tg_user_id` → private chat id.
  /// Returns number of matches added/updated/removed.
  Future<int> reconcileFromFamilyIdentities({
    required List<Map<String, dynamic>> identities,
    required Map<int, int> privateTgUserToChatId,
  }) async {
    final all = await loadAll();
    var changed = 0;
    final activeTgIds = <int>{};

    for (final row in identities) {
      final tgUserId = (row['tg_user_id'] as num?)?.toInt();
      final fcUserId = (row['user_id'] as num?)?.toInt();
      if (tgUserId == null || tgUserId <= 0) continue;
      if (fcUserId == null || fcUserId <= 0) continue;
      activeTgIds.add(tgUserId);

      final chatId = privateTgUserToChatId[tgUserId];
      if (chatId == null || chatId == 0) continue;

      final display = (row['display_name'] ?? '').toString().trim();
      final avatar = (row['avatar_url'] ?? '').toString().trim();
      final existing = all[tgUserId];
      if (existing != null &&
          existing.fcUserId == fcUserId &&
          existing.verified &&
          existing.tgChatId == chatId) {
        // Refresh display/avatar if server has better info.
        if ((display.isNotEmpty && display != existing.displayName) ||
            (avatar.isNotEmpty && avatar != existing.avatarUrl)) {
          all[tgUserId] = existing.copyWith(
            displayName: display.isNotEmpty ? display : existing.displayName,
            avatarUrl: avatar.isNotEmpty ? avatar : existing.avatarUrl,
          );
          changed++;
        }
        continue;
      }

      // Upsert / overwrite wrong fc_user (verified identity wins).
      all[tgUserId] = TelegramMatch(
        tgUserId: tgUserId,
        tgChatId: chatId,
        fcUserId: fcUserId,
        displayName: display.isNotEmpty
            ? display
            : (existing?.displayName.isNotEmpty == true
                ? existing!.displayName
                : 'Telegram'),
        avatarUrl:
            avatar.isNotEmpty ? avatar : (existing?.avatarUrl ?? ''),
        verified: true,
        fromSecretary: false,
      );
      changed++;
    }

    // Drop verified self-links whose identity is no longer active.
    // Leave manual / secretary matches (peer not logged in yet).
    final toRemove = <int>[];
    for (final e in all.entries) {
      if (!e.value.verified) continue;
      if (activeTgIds.contains(e.key)) continue;
      toRemove.add(e.key);
    }
    for (final tgId in toRemove) {
      all.remove(tgId);
      changed++;
    }

    if (changed > 0) await _persist(all);
    return changed;
  }

  Future<void> _persist(Map<int, TelegramMatch> all) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = <String, dynamic>{};
    for (final e in all.entries) {
      encoded['${e.key}'] = e.value.toJson();
    }
    await prefs.setString(_key, jsonEncode(encoded));
    revision.value++;
  }
}

class TelegramMatch {
  const TelegramMatch({
    required this.tgUserId,
    required this.tgChatId,
    required this.fcUserId,
    required this.displayName,
    this.avatarUrl = '',
    this.verified = false,
    this.fromSecretary = false,
  });

  final int tgUserId;
  final int tgChatId;
  final int fcUserId;
  final String displayName;
  final String avatarUrl;

  /// Sourced from server [TelegramTdlibIdentity] (verified login).
  final bool verified;

  /// Imported from Secretary bridge chats; not overwritten by reconcile remove.
  final bool fromSecretary;

  TelegramMatch copyWith({
    int? tgUserId,
    int? tgChatId,
    int? fcUserId,
    String? displayName,
    String? avatarUrl,
    bool? verified,
    bool? fromSecretary,
  }) {
    return TelegramMatch(
      tgUserId: tgUserId ?? this.tgUserId,
      tgChatId: tgChatId ?? this.tgChatId,
      fcUserId: fcUserId ?? this.fcUserId,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      verified: verified ?? this.verified,
      fromSecretary: fromSecretary ?? this.fromSecretary,
    );
  }

  Map<String, dynamic> toJson() => {
        'tg_user_id': tgUserId,
        'tg_chat_id': tgChatId,
        'fc_user_id': fcUserId,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'verified': verified,
        'from_secretary': fromSecretary,
      };

  factory TelegramMatch.fromJson(Map<String, dynamic> j) => TelegramMatch(
        tgUserId: (j['tg_user_id'] as num?)?.toInt() ?? 0,
        tgChatId: (j['tg_chat_id'] as num?)?.toInt() ?? 0,
        fcUserId: (j['fc_user_id'] as num?)?.toInt() ?? 0,
        displayName: j['display_name']?.toString() ?? '',
        avatarUrl: j['avatar_url']?.toString() ?? '',
        verified: j['verified'] == true,
        fromSecretary: j['from_secretary'] == true,
      );
}
