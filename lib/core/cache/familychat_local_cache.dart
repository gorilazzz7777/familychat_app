import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/chat/data/chat_realtime_utils.dart';

/// Локальный JSON-кэш метаданных (сообщения, списки альбомов) для офлайн-доступа.
abstract final class FamilyChatLocalCache {
  static const _cacheDirName = 'familychat_local_cache';
  static const messageRetentionDays = 20;
  static const maxCachedMessagesPerThread = 30;
  static const maxCachedFeedEvents = 90;
  static const maxCachedAttachmentBytes = 2 * 1024 * 1024;

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
    final kept = messages
        .where((m) {
          final id = m['id'];
          final parsed = id is int ? id : int.tryParse('$id');
          if (parsed == null) return false;
          if (parsed > 0) return true;
          return m['_pending'] == true || m['read_status'] == 'queued';
        })
        .toList();
    final slice = kept.length > maxCachedMessagesPerThread
        ? kept.sublist(kept.length - maxCachedMessagesPerThread)
        : kept;
    await writeJson(
      'messages/thread_$threadId',
      {
        'messages': sortChatMessages(slice).map(_sanitizeMessageForCache).toList(),
      },
    );
  }

  static Future<List<Map<String, dynamic>>?> readThreadMessages(int threadId) async {
    final raw = await readJson('messages/thread_$threadId');
    if (raw == null) return null;
    final list = raw['messages'];
    if (list is! List) return null;
    final restored = list
        .map((e) => _restoreMessageFromCache(Map<String, dynamic>.from(e as Map)))
        .toList();
    return sortChatMessages(restored);
  }

  static Map<String, dynamic> _sanitizeMessageForCache(Map<String, dynamic> message) {
    final copy = Map<String, dynamic>.from(message);
    final attachments = copy['attachments'];
    if (attachments is List) {
      copy['attachments'] = attachments.map((item) {
        if (item is! Map) return item;
        final att = Map<String, dynamic>.from(item);
        final local = att.remove('local_bytes');
        if (local is Uint8List && local.isNotEmpty) {
          att['local_bytes_b64'] = base64Encode(local);
        }
        return att;
      }).toList();
    }
    return copy;
  }

  static Map<String, dynamic> _restoreMessageFromCache(Map<String, dynamic> message) {
    final copy = Map<String, dynamic>.from(message);
    final attachments = copy['attachments'];
    if (attachments is List) {
      copy['attachments'] = attachments.map((item) {
        if (item is! Map) return item;
        final att = Map<String, dynamic>.from(item);
        final encoded = att.remove('local_bytes_b64');
        if (encoded is String && encoded.isNotEmpty) {
          try {
            att['local_bytes'] = base64Decode(encoded);
          } catch (_) {}
        }
        return att;
      }).toList();
    }
    return copy;
  }

  static Future<void> saveChatThreads(List<Map<String, dynamic>> threads) async {
    await writeJson('chat/threads', {
      'threads': threads,
    });
  }

  static Future<List<Map<String, dynamic>>?> readChatThreads() async {
    final raw = await readJson('chat/threads');
    if (raw == null) return null;
    final list = raw['threads'];
    if (list is! List) return null;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<void> saveChatMembers(List<Map<String, dynamic>> members) async {
    await writeJson('chat/members', {
      'members': members,
    });
  }

  static Future<List<Map<String, dynamic>>?> readChatMembers() async {
    final raw = await readJson('chat/members');
    if (raw == null) return null;
    final list = raw['members'];
    if (list is! List) return null;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static String _attachmentBytesKey(int threadId, int attachmentId) =>
      'attachments/${threadId}_$attachmentId';

  static Future<void> saveAttachmentBytes(
    int threadId,
    int attachmentId,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty || bytes.length > maxCachedAttachmentBytes) return;
    final relative = _attachmentBytesKey(threadId, attachmentId);
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fc_bin_$relative', base64Encode(bytes));
      return;
    }
    final file = await _file('$relative.bin');
    if (file == null) return;
    await file.writeAsBytes(bytes, flush: true);
  }

  static Future<Uint8List?> readAttachmentBytes(int threadId, int attachmentId) async {
    final relative = _attachmentBytesKey(threadId, attachmentId);
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString('fc_bin_$relative');
      if (encoded == null || encoded.isEmpty) return null;
      try {
        return base64Decode(encoded);
      } catch (_) {
        return null;
      }
    }
    final file = await _file('$relative.bin');
    if (file == null || !file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveOutboxBytes(String storageKey, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxCachedAttachmentBytes) return;
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fc_outbox_$storageKey', base64Encode(bytes));
      return;
    }
    final file = await _file('outbox/$storageKey.bin');
    if (file == null) return;
    await file.writeAsBytes(bytes, flush: true);
  }

  static Future<Uint8List?> readOutboxBytes(String storageKey) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString('fc_outbox_$storageKey');
      if (encoded == null || encoded.isEmpty) return null;
      try {
        return base64Decode(encoded);
      } catch (_) {
        return null;
      }
    }
    final file = await _file('outbox/$storageKey.bin');
    if (file == null || !file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteOutboxBytes(String storageKey) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fc_outbox_$storageKey');
      return;
    }
    final file = await _file('outbox/$storageKey.bin');
    if (file != null && file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<List<Map<String, dynamic>>> readOutboxItems() async {
    final raw = await readJson('chat/outbox');
    if (raw == null) return [];
    final list = raw['items'];
    if (list is! List) return [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<void> writeOutboxItems(List<Map<String, dynamic>> items) async {
    await writeJson('chat/outbox', {'items': items});
  }

  static Future<List<Map<String, dynamic>>> readScheduledItems() async {
    final raw = await readJson('chat/scheduled');
    if (raw == null) return [];
    final list = raw['items'];
    if (list is! List) return [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<void> writeScheduledItems(List<Map<String, dynamic>> items) async {
    await writeJson('chat/scheduled', {'items': items});
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
