import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Локальный JSON-кэш метаданных (сообщения, списки альбомов) для офлайн-доступа.
abstract final class FamilyChatLocalCache {
  static const _cacheDirName = 'familychat_local_cache';
  static const messageRetentionDays = 20;
  static const maxCachedMessagesPerThread = 20;
  static const maxCachedFeedEvents = 90;

  static String feedCacheKey({int? personUserId}) {
    if (personUserId == null) return 'feed/events_all';
    return 'feed/events_person_$personUserId';
  }

  static Future<Directory?> _cacheRoot() async {
    if (kIsWeb) return null;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_cacheDirName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static Future<File?> _file(String relativePath) async {
    final root = await _cacheRoot();
    if (root == null) return null;
    final file = File('${root.path}/$relativePath');
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    return file;
  }

  static bool _isFresh(DateTime? cachedAt) {
    if (cachedAt == null) return false;
    return DateTime.now().difference(cachedAt) <= const Duration(days: messageRetentionDays);
  }

  static Future<void> writeJson(String key, Map<String, dynamic> payload) async {
    final envelope = {
      'cached_at': DateTime.now().toUtc().toIso8601String(),
      ...payload,
    };
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fc_cache_$key', jsonEncode(envelope));
      return;
    }
    final file = await _file('$key.json');
    if (file == null) return;
    await file.writeAsString(jsonEncode(envelope), flush: true);
  }

  static Future<Map<String, dynamic>?> readJson(String key) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final rawText = prefs.getString('fc_cache_$key');
      if (rawText == null || rawText.isEmpty) return null;
      try {
        final raw = jsonDecode(rawText) as Map<String, dynamic>;
        final cachedAt = DateTime.tryParse(raw['cached_at']?.toString() ?? '');
        if (!_isFresh(cachedAt)) {
          await prefs.remove('fc_cache_$key');
          return null;
        }
        return raw;
      } catch (_) {
        return null;
      }
    }
    final file = await _file('$key.json');
    if (file == null || !file.existsSync()) return null;
    try {
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final cachedAt = DateTime.tryParse(raw['cached_at']?.toString() ?? '');
      if (!_isFresh(cachedAt)) {
        await file.delete();
        return null;
      }
      return raw;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveThreadMessages(
    int threadId,
    List<Map<String, dynamic>> messages,
  ) async {
    final real = messages
        .where((m) {
          final id = m['id'];
          if (id is int) return id > 0;
          return int.tryParse('$id') != null && int.parse('$id') > 0;
        })
        .toList();
    final slice = real.length > maxCachedMessagesPerThread
        ? real.sublist(real.length - maxCachedMessagesPerThread)
        : real;
    await writeJson('messages/thread_$threadId', {'messages': slice});
  }

  static Future<List<Map<String, dynamic>>?> readThreadMessages(int threadId) async {
    final raw = await readJson('messages/thread_$threadId');
    if (raw == null) return null;
    final list = raw['messages'];
    if (list is! List) return null;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<void> saveMemberAlbums(int userId, Map<String, dynamic> data) async {
    await writeJson('gallery/member_albums_$userId', {'data': data});
  }

  static Future<Map<String, dynamic>?> readMemberAlbums(int userId) async {
    final raw = await readJson('gallery/member_albums_$userId');
    final data = raw?['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }

  static Future<void> saveFamilyAlbums(Map<String, dynamic> data) async {
    await writeJson('gallery/family_albums', {'data': data});
  }

  static Future<Map<String, dynamic>?> readFamilyAlbums() async {
    final raw = await readJson('gallery/family_albums');
    final data = raw?['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }

  static Future<void> saveFeedSnapshot({
    int? personUserId,
    required Map<String, dynamic> data,
  }) async {
    await writeJson(feedCacheKey(personUserId: personUserId), {'data': data});
  }

  static Future<Map<String, dynamic>?> readFeedSnapshot({int? personUserId}) async {
    final raw = await readJson(feedCacheKey(personUserId: personUserId));
    final data = raw?['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }
}
