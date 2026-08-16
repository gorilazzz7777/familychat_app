import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../cache/familychat_local_cache.dart';
import '../local_db/chat_local_store.dart';
import 'gallery_media_export.dart';
import 'gallery_media_utils.dart';
import 'local_device_file.dart';

class MediaLocalRecord {
  const MediaLocalRecord({
    required this.key,
    this.attachmentId,
    this.path,
    this.assetId,
    this.kind = 'image',
    this.serverUrl = '',
    this.filename = '',
    this.skipPhoneAlbum = false,
    this.isOutgoing = false,
  });

  final String key;
  final int? attachmentId;
  final String? path;
  final String? assetId;
  final String kind;
  final String serverUrl;
  final String filename;
  final bool skipPhoneAlbum;
  final bool isOutgoing;

  Map<String, dynamic> toJson() => {
        'k': key,
        if (attachmentId != null) 'id': attachmentId,
        if (path != null && path!.isNotEmpty) 'path': path,
        if (assetId != null && assetId!.isNotEmpty) 'asset': assetId,
        'kind': kind,
        if (serverUrl.isNotEmpty) 'url': serverUrl,
        if (filename.isNotEmpty) 'name': filename,
        'skip': skipPhoneAlbum,
        'out': isOutgoing,
      };

  static MediaLocalRecord? fromJson(Map<String, dynamic> json) {
    final key = json['k']?.toString() ?? '';
    if (key.isEmpty) return null;
    final rawId = json['id'];
    return MediaLocalRecord(
      key: key,
      attachmentId: rawId is int ? rawId : int.tryParse('$rawId'),
      path: json['path']?.toString(),
      assetId: json['asset']?.toString(),
      kind: json['kind']?.toString() ?? 'image',
      serverUrl: json['url']?.toString() ?? '',
      filename: json['name']?.toString() ?? '',
      skipPhoneAlbum: json['skip'] == true,
      isOutgoing: json['out'] == true,
    );
  }

  MediaLocalRecord copyWith({
    String? path,
    String? assetId,
    String? serverUrl,
    String? filename,
    bool? skipPhoneAlbum,
    bool? isOutgoing,
    int? attachmentId,
  }) {
    return MediaLocalRecord(
      key: key,
      attachmentId: attachmentId ?? this.attachmentId,
      path: path ?? this.path,
      assetId: assetId ?? this.assetId,
      kind: kind,
      serverUrl: serverUrl ?? this.serverUrl,
      filename: filename ?? this.filename,
      skipPhoneAlbum: skipPhoneAlbum ?? this.skipPhoneAlbum,
      isOutgoing: isOutgoing ?? this.isOutgoing,
    );
  }
}

/// Ссылки на локальные файлы: row-per-key в Drift (native+web).
abstract final class MediaLocalIndex {
  static final Map<String, MediaLocalRecord> _mem = {};
  static Future<void>? _loading;
  static bool _loaded = false;

  static String keyForAttachmentId(int id) => 'a:$id';

  static String keyForFilename(String filename) {
    final n = GalleryMediaExport.normalizeAlbumFilename(filename);
    return n.isEmpty ? '' : 'n:$n';
  }

  static Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  static Future<void> _load() async {
    try {
      _mem.clear();
      if (ChatLocalStore.isSupported) {
        final all = await ChatLocalStore.instance.readAllMediaIndex();
        for (final entry in all.entries) {
          final rec = MediaLocalRecord.fromJson(entry.value);
          if (rec != null) _mem[rec.key] = rec;
        }
      } else {
        final raw = await FamilyChatLocalCache.readJson('media_local_index');
        if (raw != null) {
          for (final entry in raw.entries) {
            if (entry.key == 'cached_at') continue;
            if (entry.value is! Map) continue;
            final rec = MediaLocalRecord.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
            if (rec != null) _mem[rec.key] = rec;
          }
        }
      }
    } catch (e) {
      debugPrint('[MediaLocalIndex] load failed: $e');
    } finally {
      _loaded = true;
    }
  }

  static Future<void> _persistRecord(MediaLocalRecord record) async {
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.upsertMediaIndexRow(
        record.key,
        record.toJson(),
      );
      return;
    }
    // Legacy JSON fallback (should be rare once Drift web is up).
    final payload = <String, dynamic>{
      for (final rec in _mem.values) rec.key: rec.toJson(),
    };
    await FamilyChatLocalCache.writeJson('media_local_index', payload);
  }

  static Future<void> _deletePersisted(String key) async {
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.deleteMediaIndexRow(key);
      return;
    }
    final payload = <String, dynamic>{
      for (final rec in _mem.values) rec.key: rec.toJson(),
    };
    await FamilyChatLocalCache.writeJson('media_local_index', payload);
  }

  static MediaLocalRecord? peek(String key) => _mem[key];

  static MediaLocalRecord? peekByAttachmentId(int? id) {
    if (id == null) return null;
    return _mem[keyForAttachmentId(id)];
  }

  static MediaLocalRecord? peekByFilename(String? filename) {
    final key = keyForFilename(filename ?? '');
    if (key.isEmpty) return null;
    return _mem[key];
  }

  static Future<void> upsert(MediaLocalRecord record) async {
    await ensureLoaded();
    _mem[record.key] = record;
    await _persistRecord(record);
    final nameKey = keyForFilename(record.filename);
    if (nameKey.isNotEmpty && nameKey != record.key) {
      final named = record.copyWith();
      // Store under filename key as well for lookup-by-name.
      final namedRec = MediaLocalRecord(
        key: nameKey,
        attachmentId: named.attachmentId,
        path: named.path,
        assetId: named.assetId,
        kind: named.kind,
        serverUrl: named.serverUrl,
        filename: named.filename,
        skipPhoneAlbum: named.skipPhoneAlbum,
        isOutgoing: named.isOutgoing,
      );
      _mem[nameKey] = namedRec;
      await _persistRecord(namedRec);
    }
  }

  static Future<void> saveOutgoing({
    required int attachmentId,
    required String localPath,
    required String filename,
    String kind = 'image',
    String? assetId,
  }) async {
    if (localPath.trim().isEmpty) return;
    await upsert(
      MediaLocalRecord(
        key: keyForAttachmentId(attachmentId),
        attachmentId: attachmentId,
        path: localPath.trim(),
        assetId: assetId,
        kind: kind,
        filename: filename,
        isOutgoing: true,
      ),
    );
  }

  static Future<void> markSkipPhoneAlbum(String key) async {
    await ensureLoaded();
    final current = _mem[key];
    final next = current == null
        ? MediaLocalRecord(key: key, skipPhoneAlbum: true)
        : current.copyWith(skipPhoneAlbum: true, path: '');
    _mem[key] = next;
    await _persistRecord(next);
    final nameKey = keyForFilename(current?.filename ?? '');
    if (nameKey.isNotEmpty && nameKey != key) {
      final named = _mem[nameKey];
      final namedNext = named == null
          ? MediaLocalRecord(key: nameKey, skipPhoneAlbum: true)
          : named.copyWith(skipPhoneAlbum: true, path: '');
      _mem[nameKey] = namedNext;
      await _persistRecord(namedNext);
    }
  }

  static Future<void> remove(String key) async {
    await ensureLoaded();
    final rec = _mem.remove(key);
    await _deletePersisted(key);
    if (rec != null) {
      final nameKey = keyForFilename(rec.filename);
      if (nameKey.isNotEmpty) {
        _mem.remove(nameKey);
        await _deletePersisted(nameKey);
      }
    }
  }

  /// Накладывает локальный путь на payload. Не ходит в сеть.
  static void hydrateAttachment(Map<String, dynamic> attachment) {
    final id = attachment['id'] is int
        ? attachment['id'] as int
        : int.tryParse('${attachment['id']}');
    var rec = peekByAttachmentId(id);
    rec ??= peekByFilename(attachment['filename']?.toString());
    if (rec == null) return;

    attachment['skip_phone_album'] = rec.skipPhoneAlbum;
    if (rec.serverUrl.isNotEmpty && galleryAttachmentUrl(attachment).isEmpty) {
      attachment['server_url'] = rec.serverUrl;
    }
    if (rec.isOutgoing) {
      attachment['_outgoing_original'] = true;
    }
    if (rec.skipPhoneAlbum) {
      attachment.remove('local_device_path');
      attachment.remove('local_asset_id');
      return;
    }
    final path = rec.path?.trim() ?? '';
    if (path.isNotEmpty && localDeviceFileExists(path)) {
      attachment['local_device_path'] = path;
      if (rec.assetId != null && rec.assetId!.isNotEmpty) {
        attachment['local_asset_id'] = rec.assetId;
      }
      attachment['local_media_kind'] = rec.kind;
      return;
    }
    attachment.remove('local_device_path');
    attachment.remove('local_asset_id');
  }

  static void hydrateAttachments(Iterable<Map<String, dynamic>> attachments) {
    for (final att in attachments) {
      hydrateAttachment(att);
    }
  }

  static void hydrateMessage(Map<String, dynamic> message) {
    final raw = message['attachments'];
    if (raw is! List) return;
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        hydrateAttachment(item);
      } else if (item is Map) {
        hydrateAttachment(Map<String, dynamic>.from(item));
      }
    }
  }

  static void hydrateFeedEvent(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is! Map) return;
    final atts = payload['attachments'];
    if (atts is! List) return;
    for (final item in atts) {
      if (item is Map<String, dynamic>) {
        hydrateAttachment(item);
      } else if (item is Map) {
        final map = Map<String, dynamic>.from(item);
        hydrateAttachment(map);
      }
    }
  }
}
