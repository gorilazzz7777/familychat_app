import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Часто используемые чаты для «Поделиться» (direct share / сортировка в picker).
class ShareFavoriteChatEntry {
  const ShareFavoriteChatEntry({
    required this.threadId,
    required this.title,
    required this.shareCount,
    required this.lastSharedAtMs,
    this.avatarUrl,
    this.threadKind,
    this.peerUserId,
  });

  final int threadId;
  final String title;
  final int shareCount;
  final int lastSharedAtMs;
  final String? avatarUrl;
  final String? threadKind;
  final int? peerUserId;

  Map<String, dynamic> toJson() => {
        'thread_id': threadId,
        'title': title,
        'share_count': shareCount,
        'last_shared_at_ms': lastSharedAtMs,
        if (avatarUrl != null && avatarUrl!.isNotEmpty) 'avatar_url': avatarUrl,
        if (threadKind != null && threadKind!.isNotEmpty) 'thread_kind': threadKind,
        if (peerUserId != null) 'peer_user_id': peerUserId,
      };

  factory ShareFavoriteChatEntry.fromJson(Map<String, dynamic> json) {
    return ShareFavoriteChatEntry(
      threadId: int.tryParse(json['thread_id']?.toString() ?? '') ?? 0,
      title: json['title']?.toString() ?? 'Чат',
      shareCount: int.tryParse(json['share_count']?.toString() ?? '') ?? 0,
      lastSharedAtMs:
          int.tryParse(json['last_shared_at_ms']?.toString() ?? '') ?? 0,
      avatarUrl: json['avatar_url']?.toString(),
      threadKind: json['thread_kind']?.toString(),
      peerUserId: int.tryParse(json['peer_user_id']?.toString() ?? ''),
    );
  }

  ShareFavoriteChatEntry copyWith({
    String? title,
    int? shareCount,
    int? lastSharedAtMs,
    String? avatarUrl,
    String? threadKind,
    int? peerUserId,
  }) {
    return ShareFavoriteChatEntry(
      threadId: threadId,
      title: title ?? this.title,
      shareCount: shareCount ?? this.shareCount,
      lastSharedAtMs: lastSharedAtMs ?? this.lastSharedAtMs,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      threadKind: threadKind ?? this.threadKind,
      peerUserId: peerUserId ?? this.peerUserId,
    );
  }
}

abstract final class ShareFavoriteChatsStore {
  ShareFavoriteChatsStore._();

  static const _prefsKey = 'familychat_share_favorite_chats_v1';
  static const _maxStored = 24;
  static const directShareLimit = 4;

  static Future<List<ShareFavoriteChatEntry>> loadAll() async {
    if (kIsWeb) return const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => ShareFavoriteChatEntry.fromJson(
                Map<String, dynamic>.from(e),
              ))
          .where((e) => e.threadId > 0)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<ShareFavoriteChatEntry> entries) async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(entries.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  static double _score(ShareFavoriteChatEntry entry, int nowMs) {
    final ageDays =
        (nowMs - entry.lastSharedAtMs).clamp(0, 365 * 24 * 3600000) /
            86400000.0;
    final recency = 1.0 / (1.0 + ageDays / 7.0);
    return entry.shareCount * 2.0 + recency * 5.0;
  }

  static Future<List<ShareFavoriteChatEntry>> topFavorites({
    int limit = directShareLimit,
  }) async {
    final all = await loadAll();
    if (all.isEmpty) return const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final sorted = List<ShareFavoriteChatEntry>.from(all)
      ..sort((a, b) => _score(b, now).compareTo(_score(a, now)));
    return sorted.take(limit).toList();
  }

  static Future<void> recordShare({
    required int threadId,
    required String title,
    String? avatarUrl,
    String? threadKind,
    int? peerUserId,
  }) async {
    if (kIsWeb || threadId <= 0) return;
    final trimmedTitle = title.trim().isEmpty ? 'Чат' : title.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = await loadAll();
    final idx = current.indexWhere((e) => e.threadId == threadId);
    ShareFavoriteChatEntry next;
    if (idx >= 0) {
      final prev = current[idx];
      next = prev.copyWith(
        title: trimmedTitle,
        shareCount: prev.shareCount + 1,
        lastSharedAtMs: now,
        avatarUrl: avatarUrl ?? prev.avatarUrl,
        threadKind: threadKind ?? prev.threadKind,
        peerUserId: peerUserId ?? prev.peerUserId,
      );
      current[idx] = next;
    } else {
      next = ShareFavoriteChatEntry(
        threadId: threadId,
        title: trimmedTitle,
        shareCount: 1,
        lastSharedAtMs: now,
        avatarUrl: avatarUrl,
        threadKind: threadKind,
        peerUserId: peerUserId,
      );
      current.insert(0, next);
    }
    final nowMs = now;
    current.sort((a, b) => _score(b, nowMs).compareTo(_score(a, nowMs)));
    await _save(current.take(_maxStored).toList());
  }

  static Future<void> mergeThreadMetadata(
    List<Map<String, dynamic>> threads,
    Map<int, Map<String, dynamic>> memberByUserId,
  ) async {
    if (kIsWeb || threads.isEmpty) return;
    final favorites = await loadAll();
    if (favorites.isEmpty) return;
    var changed = false;
    final byId = {
      for (final t in threads)
        int.tryParse(t['id']?.toString() ?? ''): t,
    };
    for (var i = 0; i < favorites.length; i++) {
      final fav = favorites[i];
      final thread = byId[fav.threadId];
      if (thread == null) continue;
      final title = _threadTitle(thread, memberByUserId);
      final avatar = _threadAvatar(thread, memberByUserId);
      if (title != fav.title ||
          avatar != fav.avatarUrl ||
          thread['kind']?.toString() != fav.threadKind) {
        favorites[i] = fav.copyWith(
          title: title,
          avatarUrl: avatar,
          threadKind: thread['kind']?.toString(),
          peerUserId: int.tryParse(thread['peer_user_id']?.toString() ?? ''),
        );
        changed = true;
      }
    }
    if (changed) await _save(favorites);
  }

  static String _threadTitle(
    Map<String, dynamic> thread,
    Map<int, Map<String, dynamic>> memberByUserId,
  ) {
    final kind = thread['kind']?.toString();
    if (kind == 'dm' || kind == 'friend_dm') {
      final peerId = int.tryParse(thread['peer_user_id']?.toString() ?? '');
      if (peerId != null) {
        final name = memberByUserId[peerId]?['display_name']?.toString().trim();
        if (name != null && name.isNotEmpty) return name;
      }
    }
    final custom = thread['custom_title']?.toString().trim();
    if (custom != null && custom.isNotEmpty) return custom;
    return thread['title']?.toString().trim().isNotEmpty == true
        ? thread['title'].toString().trim()
        : 'Чат';
  }

  static String? _threadAvatar(
    Map<String, dynamic> thread,
    Map<int, Map<String, dynamic>> memberByUserId,
  ) {
    final fromThread = thread['peer_avatar_url']?.toString().trim();
    if (fromThread != null && fromThread.isNotEmpty) return fromThread;
    final peerId = int.tryParse(thread['peer_user_id']?.toString() ?? '');
    if (peerId == null) return null;
    final url = memberByUserId[peerId]?['avatar_url']?.toString().trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }
}
