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
  /// Быстрая первая страница при открытии чата.
  static const initialMessagesPageSize = 10;
  /// Догрузка старше в фоне после первой отрисовки (10+20=30).
  static const backfillMessagesPageSize = 20;
  static const maxCachedMessagesPerThread = 30;
  static const maxCachedFeedEvents = 90;
  /// Лимит для bin-кэша вложений (web SharedPreferences + диск).
  /// Раньше 2MB — чужие фото часто не сохранялись, свои жили через local_bytes в JSON.
  static const maxCachedAttachmentBytes = 6 * 1024 * 1024;

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
    final encoded = jsonEncode(envelope);
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final ok = await prefs.setString('fc_cache_$key', encoded);
      if (!ok) {
        throw StateError('SharedPreferences quota exceeded for $key');
      }
      return;
    }
    final file = await _file('$key.json');
    if (file == null) return;
    await file.writeAsString(encoded, flush: true);
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

  /// Оставляет не больше [maxCachedMessagesPerThread] самых новых + pending.
  static List<Map<String, dynamic>> newestCacheWindow(
    List<Map<String, dynamic>> messages,
  ) {
    final sorted = sortChatMessages(messages);
    final pending = sorted.where(chatMessageIsPending).toList();
    final server = sorted.where((m) => !chatMessageIsPending(m)).toList();
    final serverSlice = server.length > maxCachedMessagesPerThread
        ? server.sublist(server.length - maxCachedMessagesPerThread)
        : server;
    return sortChatMessages([...serverSlice, ...pending]);
  }

  static Future<void> saveThreadMessages(
    int threadId,
    List<Map<String, dynamic>> messages, {
    /// Устарело: не используем merge старого окна — он оставлял сообщения
    /// на ~20 позиций выше актуального хвоста. Pending подмешиваем отдельно.
    bool mergeWithExisting = false,
  }) async {
    final kept = messages
        .where((m) {
          final id = m['id'];
          final parsed = id is int ? id : int.tryParse('$id');
          if (parsed == null) return false;
          if (parsed > 0) return true;
          return m['_pending'] == true || m['read_status'] == 'queued';
        })
        .toList();

    var sorted = newestCacheWindow(kept);

    if (mergeWithExisting) {
      final existing = await readThreadMessages(threadId);
      if (existing != null && existing.isNotEmpty) {
        final incomingNewest = chatNewestServerMessageId(sorted);
        final existingNewest = chatNewestServerMessageId(existing);
        // Только если диск новее/равен сети — сохраняем pending с диска.
        // Если сеть новее — полный replace окна (иначе залипает старый диапазон).
        if (incomingNewest != null &&
            existingNewest != null &&
            incomingNewest >= existingNewest) {
          final pending = existing.where(chatMessageIsPending).toList();
          if (pending.isNotEmpty) {
            sorted = newestCacheWindow([...sorted, ...pending]);
          }
        } else if (incomingNewest == null ||
            existingNewest == null ||
            incomingNewest < existingNewest) {
          // Входящие старее диска — не затираем более свежий локальный хвост.
          sorted = newestCacheWindow(
            chatMergeMessageLists(existing, sorted),
          );
        }
      }
    }

    for (final message in sorted) {
      await _extractInlineAttachmentBytes(threadId, message);
    }

    await writeJson(
      'messages/thread_$threadId',
      {
        'messages': sorted.map(_sanitizeMessageForCache).toList(),
      },
    );
  }

  /// Подставляет local_bytes из bin-кэша — и свои, и входящие превью.
  static Future<List<Map<String, dynamic>>> hydrateAttachmentBytes(
    int threadId,
    List<Map<String, dynamic>> messages,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (final message in messages) {
      final copy = Map<String, dynamic>.from(message);
      final rawAtts = copy['attachments'];
      if (rawAtts is! List || rawAtts.isEmpty) {
        out.add(copy);
        continue;
      }
      final nextAtts = <dynamic>[];
      for (final item in rawAtts) {
        if (item is! Map) {
          nextAtts.add(item);
          continue;
        }
        final att = chatNormalizeMap(Map<dynamic, dynamic>.from(item));
        final existing = att['local_bytes'];
        if (existing is! Uint8List || existing.isEmpty) {
          final attachmentId = chatAsInt(att['id']);
          if (attachmentId != null && attachmentId > 0) {
            final stored = await readAttachmentBytes(threadId, attachmentId);
            if (stored != null && stored.isNotEmpty) {
              att['local_bytes'] = stored;
            }
          }
        }
        nextAtts.add(att);
      }
      copy['attachments'] = nextAtts;
      out.add(copy);
    }
    return out;
  }

  static Future<void> _extractInlineAttachmentBytes(
    int threadId,
    Map<String, dynamic> message,
  ) async {
    final attachments = message['attachments'];
    if (attachments is! List) return;
    for (final item in attachments) {
      if (item is! Map) continue;
      final att = item;
      final attachmentId = chatAsInt(att['id']);
      if (attachmentId == null || attachmentId <= 0) continue;

      Uint8List? bytes;
      final local = att['local_bytes'];
      if (local is Uint8List && local.isNotEmpty) {
        bytes = local;
      } else {
        final encoded = att['local_bytes_b64'];
        if (encoded is String && encoded.isNotEmpty) {
          try {
            bytes = base64Decode(encoded);
          } catch (_) {}
        }
      }
      if (bytes == null || bytes.isEmpty) continue;
      try {
        await saveAttachmentBytes(threadId, attachmentId, bytes);
      } catch (_) {}
    }
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
    final copy = chatNormalizeMap(Map<dynamic, dynamic>.from(message));
    // Эфемерные клиентские флаги отправки не кладём в долговременный кэш.
    copy.remove('_failed');
    _ensureSystemCallFields(copy);
    final attachments = copy['attachments'];
    if (attachments is List) {
      copy['attachments'] = attachments.map((item) {
        if (item is! Map) return item;
        final att = chatNormalizeMap(Map<dynamic, dynamic>.from(item));
        // Никогда не кладём байты в JSON сообщений — только метаданные как у API.
        att.remove('local_bytes');
        att.remove('local_bytes_b64');
        return att;
      }).toList();
    }
    return copy;
  }

  static Map<String, dynamic> _restoreMessageFromCache(Map<String, dynamic> message) {
    final copy = chatNormalizeMap(Map<dynamic, dynamic>.from(message));
    _ensureSystemCallFields(copy);
    final attachments = copy['attachments'];
    if (attachments is List) {
      copy['attachments'] = attachments.map((item) {
        if (item is! Map) return item;
        final att = chatNormalizeMap(Map<dynamic, dynamic>.from(item));
        // Legacy: старые кэши могли держать b64 inline — снимем в память на один кадр,
        // saveThreadMessages мигрирует в bin при следующей записи.
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

  /// Баннеры звонков завязаны на is_system + metadata.kind=call.
  static void _ensureSystemCallFields(Map<String, dynamic> message) {
    final rawMeta = message['metadata'];
    if (rawMeta is Map) {
      message['metadata'] = chatNormalizeMap(Map<dynamic, dynamic>.from(rawMeta));
    }
    final meta = message['metadata'];
    if (meta is Map && meta['kind']?.toString() == 'call') {
      message['is_system'] = true;
    } else if (message['is_system'] == true ||
        message['is_system'] == 1 ||
        message['is_system']?.toString() == 'true') {
      message['is_system'] = true;
    }
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

  static Future<void> saveStatus(Map<String, dynamic> status) async {
    await writeJson('session/status', {
      'status': status,
    });
  }

  static Future<Map<String, dynamic>?> readStatus() async {
    final raw = await readJson('session/status');
    if (raw == null) return null;
    final status = raw['status'];
    if (status is! Map) return null;
    return Map<String, dynamic>.from(status);
  }

  static Future<void> clearStatus() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fc_cache_session/status');
      return;
    }
    final file = await _file('session/status.json');
    if (file != null && file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
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

  static const maxCachedAlbumPhotosPage = 60;

  static String albumPhotosCacheKey({
    required bool isFamilyGallery,
    required int userId,
    required String albumId,
    String query = '',
    int? personUserId,
    bool personUnidentified = false,
  }) {
    final scope = isFamilyGallery ? 'family' : 'member_$userId';
    final q = query.trim().toLowerCase();
    final person = personUnidentified
        ? 'unidentified'
        : (personUserId?.toString() ?? 'all');
    final safeAlbum = albumId.replaceAll(RegExp(r'[^a-zA-Z0-9_.:-]'), '_');
    return 'gallery/photos/${scope}_$safeAlbum'
        '_q${q.hashCode}_p$person';
  }

  static Future<void> saveAlbumPhotosPage({
    required bool isFamilyGallery,
    required int userId,
    required String albumId,
    required Map<String, dynamic> data,
    String query = '',
    int? personUserId,
    bool personUnidentified = false,
  }) async {
    await writeJson(
      albumPhotosCacheKey(
        isFamilyGallery: isFamilyGallery,
        userId: userId,
        albumId: albumId,
        query: query,
        personUserId: personUserId,
        personUnidentified: personUnidentified,
      ),
      {'data': data},
    );
  }

  static Future<Map<String, dynamic>?> readAlbumPhotosPage({
    required bool isFamilyGallery,
    required int userId,
    required String albumId,
    String query = '',
    int? personUserId,
    bool personUnidentified = false,
  }) async {
    final raw = await readJson(
      albumPhotosCacheKey(
        isFamilyGallery: isFamilyGallery,
        userId: userId,
        albumId: albumId,
        query: query,
        personUserId: personUserId,
        personUnidentified: personUnidentified,
      ),
    );
    final data = raw?['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }

  static String calendarMonthKey({required int year, required int month}) =>
      'calendar/month_${year}_$month';

  static Future<void> saveCalendarMonth({
    required int year,
    required int month,
    required Map<String, dynamic> data,
  }) async {
    await writeJson(calendarMonthKey(year: year, month: month), {'data': data});
  }

  static Future<Map<String, dynamic>?> readCalendarMonth({
    required int year,
    required int month,
  }) async {
    final raw = await readJson(calendarMonthKey(year: year, month: month));
    final data = raw?['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  }
}
