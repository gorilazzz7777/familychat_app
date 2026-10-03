import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/cache/familychat_media_cache.dart';
import 'chat_hub_folders.dart';
import 'chat_realtime_utils.dart';

/// Frozen top-N hub rows + shell avatar for cold-start first paint (no skeleton).
abstract final class HubFirstPaintSnapshot {
  static const maxRows = 15;
  static const _jsonKey = 'hub/first_paint_v1';
  static const _avatarDirName = 'hub_avatar_cache';
  static const _profileAvatarFile = 'profile.jpg';

  /// In-memory hint so shell can paint before async read finishes.
  static String? _cachedProfileAvatarPath;
  static String? _cachedProfileAvatarUrl;

  static String? get cachedProfileAvatarPath => _cachedProfileAvatarPath;
  static String? get cachedProfileAvatarUrl => _cachedProfileAvatarUrl;

  static Future<Directory?> _avatarDir() async {
    if (kIsWeb) return null;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_avatarDirName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static String _safeFileKey(String rowKey) {
    return rowKey.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  static Future<String?> profileAvatarPath() async {
    if (kIsWeb) return null;
    final dir = await _avatarDir();
    if (dir == null) return null;
    final file = File('${dir.path}/$_profileAvatarFile');
    if (!file.existsSync()) return null;
    // Empty stub left by a failed cache copy — treat as missing so AppBar
    // falls through to the network avatar_url (profile screen already does).
    if (file.lengthSync() <= 0) {
      try {
        await file.delete();
      } catch (_) {}
      if (_cachedProfileAvatarPath == file.path) {
        _cachedProfileAvatarPath = null;
      }
      return null;
    }
    _cachedProfileAvatarPath = file.path;
    return file.path;
  }

  static Future<HubFirstPaintData?> read() async {
    if (kIsWeb) return null;
    final raw = await FamilyChatLocalCache.readJson(_jsonKey);
    if (raw == null) return null;
    final list = raw['rows'];
    if (list is! List || list.isEmpty) return null;
    final rows = <Map<String, dynamic>>[];
    for (final e in list) {
      if (e is! Map) continue;
      rows.add(_decodeRow(Map<String, dynamic>.from(e)));
    }
    if (rows.isEmpty) return null;
    final profileUrl = raw['profile_avatar_url']?.toString();
    final profilePath = raw['profile_avatar_path']?.toString();
    var resolvedProfile = profilePath;
    if (resolvedProfile == null ||
        resolvedProfile.isEmpty ||
        !File(resolvedProfile).existsSync()) {
      resolvedProfile = await profileAvatarPath();
    } else {
      _cachedProfileAvatarPath = resolvedProfile;
    }
    if (profileUrl != null && profileUrl.isNotEmpty) {
      _cachedProfileAvatarUrl = profileUrl;
    }
    return HubFirstPaintData(
      rows: rows,
      profileAvatarUrl: profileUrl,
      profileAvatarPath: resolvedProfile,
    );
  }

  /// Update only the shell avatar fields without wiping hub rows.
  static Future<void> writeProfileAvatar({
    String? profileAvatarUrl,
    String? profileAvatarSourcePath,
  }) async {
    if (kIsWeb) return;
    final current = await read();
    final rows = current?.rows ?? const <Map<String, dynamic>>[];
    await write(
      rows: rows,
      profileAvatarUrl: profileAvatarUrl ?? current?.profileAvatarUrl,
      profileAvatarSourcePath: profileAvatarSourcePath,
    );
  }

  static Future<void> write({
    required List<Map<String, dynamic>> rows,
    String? profileAvatarUrl,
    String? profileAvatarSourcePath,
  }) async {
    if (kIsWeb) return;
    final top = rows.take(maxRows).toList(growable: false);
    final encoded = <Map<String, dynamic>>[];
    for (final row in top) {
      encoded.add(await _encodeRow(row));
    }

    String? profilePath = await profileAvatarPath();
    final url = profileAvatarUrl?.trim();
    if (url != null && url.isNotEmpty) {
      _cachedProfileAvatarUrl = url;
      final copied = await _ensureProfileAvatar(
        url: url,
        sourcePath: profileAvatarSourcePath,
      );
      if (copied != null) profilePath = copied;
    } else if (profileAvatarSourcePath != null &&
        profileAvatarSourcePath.isNotEmpty) {
      final copied = await _copyFileToProfile(profileAvatarSourcePath);
      if (copied != null) profilePath = copied;
    }

    await FamilyChatLocalCache.writeJson(_jsonKey, {
      'rows': encoded,
      if (url != null && url.isNotEmpty) 'profile_avatar_url': url,
      if (profilePath != null && profilePath.isNotEmpty)
        'profile_avatar_path': profilePath,
    });
  }

  /// Soft-update one FC / TG row already present in the snapshot (push path).
  static Future<void> patchRow({
    int? threadId,
    int? tdlibChatId,
    String? title,
    String? lastBody,
    String? lastCreatedAt,
    int? unreadCount,
    bool bumpUnread = false,
  }) async {
    if (kIsWeb) return;
    if (threadId == null && tdlibChatId == null) return;
    final current = await read();
    if (current == null || current.rows.isEmpty) return;
    var changed = false;
    final next = <Map<String, dynamic>>[];
    for (final row in current.rows) {
      final copy = Map<String, dynamic>.from(row);
      final kind = copy['kind']?.toString() ?? '';
      final isTg = kind == 'tdlib_dm' || kind == 'tdlib_chat';
      var match = false;
      if (threadId != null && !isTg) {
        final id = chatAsInt(copy['id']);
        match = id == threadId;
      } else if (tdlibChatId != null) {
        final tg = (copy['tdlib_chat_id'] as num?)?.toInt() ??
            chatAsInt(copy['tdlib_chat_id']);
        match = tg == tdlibChatId;
      }
      if (match) {
        if (title != null && title.trim().isNotEmpty) {
          copy['title'] = title.trim();
        }
        if (lastBody != null || lastCreatedAt != null) {
          final lm = Map<String, dynamic>.from(
            (copy['last_message'] is Map)
                ? Map<String, dynamic>.from(copy['last_message'] as Map)
                : <String, dynamic>{},
          );
          if (lastBody != null) lm['body'] = lastBody;
          if (lastCreatedAt != null) lm['created_at'] = lastCreatedAt;
          copy['last_message'] = lm;
        }
        if (unreadCount != null) {
          copy['unread_count'] = unreadCount;
        } else if (bumpUnread) {
          final prev = chatAsInt(copy['unread_count']) ?? 0;
          copy['unread_count'] = prev + 1;
        }
        changed = true;
      }
      next.add(copy);
    }
    if (!changed) return;
    // Move patched row to top (most recent activity).
    next.sort((a, b) {
      final aMatch = _rowMatches(a, threadId: threadId, tdlibChatId: tdlibChatId);
      final bMatch = _rowMatches(b, threadId: threadId, tdlibChatId: tdlibChatId);
      if (aMatch && !bMatch) return -1;
      if (!aMatch && bMatch) return 1;
      return 0;
    });
    await FamilyChatLocalCache.writeJson(_jsonKey, {
      'rows': [for (final r in next.take(maxRows)) await _encodeRow(r)],
      if (current.profileAvatarUrl != null)
        'profile_avatar_url': current.profileAvatarUrl,
      if (current.profileAvatarPath != null)
        'profile_avatar_path': current.profileAvatarPath,
    });
  }

  static bool _rowMatches(
    Map<String, dynamic> row, {
    int? threadId,
    int? tdlibChatId,
  }) {
    if (threadId != null) {
      final kind = row['kind']?.toString() ?? '';
      if (kind != 'tdlib_dm' && kind != 'tdlib_chat') {
        return chatAsInt(row['id']) == threadId;
      }
    }
    if (tdlibChatId != null) {
      final tg = (row['tdlib_chat_id'] as num?)?.toInt() ??
          chatAsInt(row['tdlib_chat_id']);
      return tg == tdlibChatId;
    }
    return false;
  }

  static Future<Map<String, dynamic>> _encodeRow(
    Map<String, dynamic> row,
  ) async {
    final out = Map<String, dynamic>.from(row);
    // Drop non-JSON / transient fields.
    out.remove('tdlib_photo_bytes');
    final rowKey = ChatFolderMemberKey.forHubRow(out) ??
        '${out['kind']}:${out['id']}';
    final srcPath = out['tdlib_photo_path']?.toString();
    if (srcPath != null && srcPath.isNotEmpty) {
      final copied = await _copyAvatarFile(rowKey, srcPath);
      if (copied != null) {
        out['tdlib_photo_path'] = copied;
      }
    }
    // Keep a compact minithumbnail fallback when no file.
    final bytes = row['tdlib_photo_bytes'];
    if ((out['tdlib_photo_path'] == null ||
            out['tdlib_photo_path'].toString().isEmpty) &&
        bytes is List &&
        bytes.isNotEmpty) {
      final list = bytes is Uint8List
          ? bytes
          : Uint8List.fromList(List<int>.from(bytes));
      if (list.length <= 8 * 1024) {
        out['tdlib_photo_b64'] = base64Encode(list);
      }
    }
    return out;
  }

  static Map<String, dynamic> _decodeRow(Map<String, dynamic> raw) {
    final out = Map<String, dynamic>.from(raw);
    final b64 = out.remove('tdlib_photo_b64')?.toString();
    if (b64 != null && b64.isNotEmpty) {
      try {
        out['tdlib_photo_bytes'] = base64Decode(b64);
      } catch (_) {}
    }
    final path = out['tdlib_photo_path']?.toString();
    if (path != null && path.isNotEmpty && !File(path).existsSync()) {
      out.remove('tdlib_photo_path');
    }
    return out;
  }

  static Future<String?> _copyAvatarFile(String rowKey, String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!src.existsSync()) return null;
      final dir = await _avatarDir();
      if (dir == null) return null;
      final dest = File('${dir.path}/${_safeFileKey(rowKey)}.jpg');
      if (dest.existsSync()) {
        final srcStat = src.statSync();
        final destStat = dest.statSync();
        if (destStat.size == srcStat.size &&
            !srcStat.modified.isAfter(destStat.modified)) {
          return dest.path;
        }
      }
      await src.copy(dest.path);
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _ensureProfileAvatar({
    required String url,
    String? sourcePath,
  }) async {
    if (sourcePath != null && sourcePath.isNotEmpty) {
      final copied = await _copyFileToProfile(sourcePath);
      if (copied != null) return copied;
    }
    try {
      final cached = await FamilyChatMediaCache.preview.getFileFromCache(url);
      if (cached != null) {
        final copied = await _copyFileToProfile(cached.file.path);
        if (copied != null) return copied;
      }
    } catch (_) {}
    // Cache miss / empty — download once so shell AppBar has a real file.
    try {
      final downloaded =
          await FamilyChatMediaCache.preview.getSingleFile(url);
      final copied = await _copyFileToProfile(downloaded.path);
      if (copied != null) return copied;
    } catch (_) {}
    return profileAvatarPath();
  }

  static Future<String?> _copyFileToProfile(String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!src.existsSync() || src.lengthSync() <= 0) return null;
      final dir = await _avatarDir();
      if (dir == null) return null;
      final dest = File('${dir.path}/$_profileAvatarFile');
      await src.copy(dest.path);
      if (!dest.existsSync() || dest.lengthSync() <= 0) {
        try {
          await dest.delete();
        } catch (_) {}
        return null;
      }
      _cachedProfileAvatarPath = dest.path;
      return dest.path;
    } catch (_) {
      return null;
    }
  }
}

class HubFirstPaintData {
  const HubFirstPaintData({
    required this.rows,
    this.profileAvatarUrl,
    this.profileAvatarPath,
  });

  final List<Map<String, dynamic>> rows;
  final String? profileAvatarUrl;
  final String? profileAvatarPath;
}
