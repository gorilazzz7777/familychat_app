import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/cache/familychat_media_cache.dart';
import '../../../core/local_db/chat_local_store.dart';
import 'chat_hub_folders.dart';
import 'chat_message_preview.dart';
import 'chat_realtime_utils.dart';

/// Frozen top-N hub rows + shell avatar for cold-start first paint (no skeleton).
///
/// Durable in **SQLite** [`ChatMetaRows`] (`hub_first_paint_v1`) and mirrored to
/// the JSON file cache (avatars still live as files under support dir).
abstract final class HubFirstPaintSnapshot {
  /// Persist a large merged hub so cold start ≈ full list (not top-15 drip).
  static const maxRows = 200;
  static const _jsonKey = 'hub/first_paint_v1';
  static const _metaKey = 'hub_first_paint_v1';
  static const _avatarDirName = 'hub_avatar_cache';
  static const _profileAvatarFile = 'profile.jpg';

  /// In-memory hint so shell can paint before async read finishes.
  static String? _cachedProfileAvatarPath;
  static String? _cachedProfileAvatarUrl;

  /// Preloaded during bootstrap so [ChatHubScreen] can paint frame 0.
  static const _foldersMetaKey = 'hub_folders_v1';
  static const _chipsMetaKey = 'hub_chips_v1';

  static HubFirstPaintData? _warmed;
  static List<Map<String, dynamic>>? _warmedFcThreads;
  static List<Map<String, dynamic>>? _warmedFolders;
  static List<Map<String, dynamic>>? _warmedChips;
  static Future<HubFirstPaintData?>? _warming;

  static String? get cachedProfileAvatarPath => _cachedProfileAvatarPath;
  static String? get cachedProfileAvatarUrl => _cachedProfileAvatarUrl;

  /// Full FC thread list from SQLite (includes last_message) — preferred over
  /// the truncated snapshot FC subset for first paint.
  static List<Map<String, dynamic>>? get warmedFcThreads => _warmedFcThreads;

  /// Last-known FC custom folders (chip bar) — avoids folder drip on cold start.
  static List<Map<String, dynamic>>? get warmedFolders => _warmedFolders;

  /// Last-known hub chips incl. TG folders (Работа / Личное / …).
  static List<Map<String, dynamic>>? get warmedChips => _warmedChips;

  static Future<void> persistFolders(List<Map<String, dynamic>> raw) async {
    if (kIsWeb) return;
    try {
      await ChatLocalStore.instance.ensureOpen();
      await ChatLocalStore.instance.metaSet(_foldersMetaKey, jsonEncode(raw));
      _warmedFolders = [
        for (final e in raw) Map<String, dynamic>.from(e),
      ];
    } catch (e) {
      debugPrint('[hub-snapshot] persist folders failed: $e');
    }
  }

  static Future<void> persistChips(List<HubChip> chips) async {
    if (kIsWeb || chips.isEmpty) return;
    final raw = <Map<String, dynamic>>[
      for (final c in chips)
        {
          'key': c.key,
          'label': c.label,
          if (c.system != null) 'system': c.system!.name,
          if (c.folderId != null) 'folderId': c.folderId,
          if (c.tgFolderId != null) 'tgFolderId': c.tgFolderId,
          if (c.folderName != null) 'folderName': c.folderName,
        },
    ];
    try {
      await ChatLocalStore.instance.ensureOpen();
      await ChatLocalStore.instance.metaSet(_chipsMetaKey, jsonEncode(raw));
      _warmedChips = raw;
    } catch (e) {
      debugPrint('[hub-snapshot] persist chips failed: $e');
    }
  }

  static List<HubChip> chipsFromWarm() {
    final raw = _warmedChips;
    if (raw == null || raw.isEmpty) return const [];
    final out = <HubChip>[];
    for (final e in raw) {
      final systemName = e['system']?.toString();
      if (systemName != null && systemName.isNotEmpty) {
        ChatHubSystemFilter? sys;
        for (final v in ChatHubSystemFilter.values) {
          if (v.name == systemName) {
            sys = v;
            break;
          }
        }
        if (sys != null) out.add(HubChip.system(sys));
        continue;
      }
      final tgId = (e['tgFolderId'] as num?)?.toInt();
      if (tgId != null) {
        out.add(
          HubChip.telegram(
            id: tgId,
            name: e['folderName']?.toString() ?? e['label']?.toString() ?? 'Папка',
          ),
        );
        continue;
      }
      final fcId = (e['folderId'] as num?)?.toInt();
      if (fcId != null) {
        out.add(
          HubChip.custom(
            id: fcId,
            name: e['folderName']?.toString() ?? e['label']?.toString() ?? 'Папка',
          ),
        );
      }
    }
    return out;
  }

  /// Start loading into RAM (idempotent). Call from bootstrap / shell early.
  static Future<HubFirstPaintData?> warm() {
    if (kIsWeb) return Future<HubFirstPaintData?>.value(null);
    if (_warmed != null && _warmedFcThreads != null) {
      return Future.value(_warmed);
    }
    return _warming ??= _warmBody();
  }

  /// Wait for [warm] up to [budget], then continue (warm keeps running).
  /// Used on cache-first boot so ChatHub can paint frame-0 rows.
  static Future<void> warmWithBudget([
    Duration budget = const Duration(milliseconds: 120),
  ]) async {
    if (kIsWeb) return;
    if (_warmed != null && _warmedFcThreads != null) return;
    final f = warm();
    await Future.any<void>([
      f.then((_) {}),
      Future<void>.delayed(budget),
    ]);
  }

  static Future<HubFirstPaintData?> _warmBody() async {
    HubFirstPaintData? data;
    try {
      await ChatLocalStore.instance.ensureOpen();
      // Snapshot FIRST (TG synthetics for frame-0). FC thread hydrate can
      // exceed warmWithBudget(120ms) and left hub painted FC-only while
      // `_hydrateFromSnapshot` bailed on `_paintedFromSnapshot`.
      data = await read();
      _warmed = data;
      final foldersRaw = await ChatLocalStore.instance.metaGet(_foldersMetaKey);
      if (foldersRaw != null && foldersRaw.isNotEmpty) {
        final decoded = jsonDecode(foldersRaw);
        if (decoded is List) {
          _warmedFolders = [
            for (final e in decoded)
              if (e is Map) Map<String, dynamic>.from(e),
          ];
        }
      }
      final chipsRaw = await ChatLocalStore.instance.metaGet(_chipsMetaKey);
      if (chipsRaw != null && chipsRaw.isNotEmpty) {
        final decoded = jsonDecode(chipsRaw);
        if (decoded is List) {
          _warmedChips = [
            for (final e in decoded)
              if (e is Map) Map<String, dynamic>.from(e),
          ];
        }
      }
      final threads = await ChatLocalStore.instance.readThreads();
      if (threads.isNotEmpty) {
        // Fill empty hub last_message from SQLite tip so sort/previews match
        // live enrich (avoids Киса jumping into the list seconds later).
        _warmedFcThreads = await hydrateFcThreadsLastMessages(threads);
      }
    } catch (e) {
      debugPrint('[hub-snapshot] warm FC threads failed: $e');
    }
    data ??= await read();
    _warmed = data;
    _warming = null;
    return data;
  }

  /// Prefer thread.last_message; if body empty, use newest local message.
  static Future<List<Map<String, dynamic>>> hydrateFcThreadsLastMessages(
    List<Map<String, dynamic>> threads,
  ) async {
    final filled = <Map<String, dynamic>>[];
    for (final thread in threads) {
      final copy = Map<String, dynamic>.from(thread);
      final id = chatAsInt(copy['id']);
      final last = copy['last_message'];
      final body = last is Map ? last['body']?.toString().trim() ?? '' : '';
      if (id != null && body.isEmpty) {
        try {
          final tip = await ChatLocalStore.instance.readMessagesTail(
            id,
            limit: 1,
          );
          if (tip.isNotEmpty) {
            copy['last_message'] = Map<String, dynamic>.from(tip.last);
          }
        } catch (_) {}
      }
      filled.add(copy);
    }
    return enrichChatThreadsLastMessages(filled);
  }

  /// Snapshot for synchronous apply in [State.initState] (does not clear).
  static HubFirstPaintData? get warmed => _warmed;

  /// TG synthetic row stored in Archive (same hub snapshot / SQLite meta).
  static bool isArchivedTgRow(Map<String, dynamic> row) {
    if (row['tdlib_archived'] == true) return true;
    final kind = row['kind']?.toString() ?? '';
    return kind == 'tdlib_archive_chat';
  }

  /// TG hub synthetics from a snapshot payload (main list vs Archive).
  static ({List<Map<String, dynamic>> main, List<Map<String, dynamic>> archive})
      splitTgRows(Iterable<Map<String, dynamic>> rows) {
    final main = <Map<String, dynamic>>[];
    final archive = <Map<String, dynamic>>[];
    for (final row in rows) {
      final kind = row['kind']?.toString() ?? '';
      if (kind == 'tdlib_archive') continue;
      if (kind != 'tdlib_dm' &&
          kind != 'tdlib_chat' &&
          kind != 'tdlib_archive_chat') {
        continue;
      }
      final copy = Map<String, dynamic>.from(row);
      if (isArchivedTgRow(copy)) {
        // Normalize kind so restore/upsert match main TG synthetics.
        if (copy['kind']?.toString() == 'tdlib_archive_chat') {
          copy['kind'] = 'tdlib_chat';
        }
        copy['tdlib_archived'] = true;
        archive.add(copy);
      } else {
        copy['tdlib_archived'] = false;
        main.add(copy);
      }
    }
    return (main: main, archive: archive);
  }

  /// Consume warmed data once (optional).
  static HubFirstPaintData? takeWarmed() {
    final data = _warmed;
    _warmed = null;
    return data;
  }

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
    // Prefer SQLite (survives process death; not cancelled by dispose timers).
    try {
      await ChatLocalStore.instance.ensureOpen();
      final raw = await ChatLocalStore.instance.metaGet(_metaKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final data = await _parsePayload(Map<String, dynamic>.from(decoded));
          if (data != null) return data;
        }
      }
    } catch (e) {
      debugPrint('[hub-snapshot] sqlite read failed: $e');
    }
    final fileRaw = await FamilyChatLocalCache.readJson(_jsonKey);
    if (fileRaw == null) return null;
    return _parsePayload(fileRaw);
  }

  static Future<HubFirstPaintData?> _parsePayload(
    Map<String, dynamic> raw,
  ) async {
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
    for (var i = 0; i < top.length; i++) {
      encoded.add(await _encodeRow(top[i]));
      // Let open-chat / frames breathe during large cold-boot snapshot writes.
      if (i > 0 && i % 24 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
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

    final payload = <String, dynamic>{
      'cached_at': DateTime.now().toUtc().toIso8601String(),
      'rows': encoded,
      if (url != null && url.isNotEmpty) 'profile_avatar_url': url,
      if (profilePath != null && profilePath.isNotEmpty)
        'profile_avatar_path': profilePath,
    };

    // Keep RAM warm for next cold open in the same process / next launch path.
    _warmed = HubFirstPaintData(
      rows: [
        for (final r in encoded) _decodeRow(Map<String, dynamic>.from(r)),
      ],
      profileAvatarUrl: url,
      profileAvatarPath: profilePath,
    );

    try {
      await ChatLocalStore.instance.ensureOpen();
      await ChatLocalStore.instance.metaSet(_metaKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('[hub-snapshot] sqlite write failed: $e');
    }
    try {
      await FamilyChatLocalCache.writeJson(_jsonKey, payload);
    } catch (e) {
      debugPrint('[hub-snapshot] file write failed: $e');
    }
  }

  /// Replace or insert one full hub row (FC thread or TG synthetic).
  ///
  /// Keeps cold-start unread/last_message in sync when the hub screen is not
  /// mounted (new message + read inbox), including muted chats.
  static Future<void> upsertFullRow(Map<String, dynamic> row) async {
    if (kIsWeb || row.isEmpty) return;
    await upsertFullRows([row]);
  }

  /// Merge many hub rows with a single read + write.
  ///
  /// Boot used to fire [upsertFullRow]×N in parallel — each call re-read and
  /// re-wrote the full snapshot (incl. avatar encode). Opening a chat right
  /// after `hub-snapshot flush soon n=154` froze the UI isolate ~20s.
  static Future<void> upsertFullRows(List<Map<String, dynamic>> rows) async {
    if (kIsWeb || rows.isEmpty) return;
    final incomingList = <Map<String, dynamic>>[
      for (final r in rows)
        if (r.isNotEmpty) Map<String, dynamic>.from(r),
    ];
    if (incomingList.isEmpty) return;

    final current = await read();
    final next = <Map<String, dynamic>>[
      for (final e in current?.rows ?? const <Map<String, dynamic>>[])
        Map<String, dynamic>.from(e),
    ];

    for (final incoming in incomingList) {
      final kind = incoming['kind']?.toString() ?? '';
      if (kind == 'tdlib_archive') {
        // Folder chrome row — replace any previous archive folder entry.
        var replacedFolder = false;
        for (var i = 0; i < next.length; i++) {
          if (next[i]['kind']?.toString() == 'tdlib_archive') {
            next[i] = Map<String, dynamic>.from(incoming);
            replacedFolder = true;
            break;
          }
        }
        if (!replacedFolder) next.add(Map<String, dynamic>.from(incoming));
        continue;
      }
      final isTg = kind == 'tdlib_dm' ||
          kind == 'tdlib_chat' ||
          kind == 'tdlib_archive_chat';
      final threadId = isTg ? null : chatAsInt(incoming['id']);
      final tdlibChatId = chatAsInt(incoming['tdlib_chat_id']) ??
          _linkedTgChatId(incoming);
      var replaced = false;
      for (var i = 0; i < next.length; i++) {
        final match = _rowMatchesFull(
          next[i],
          threadId: threadId,
          tdlibChatId: tdlibChatId,
        );
        if (!match) continue;
        next[i] = _mergeFullHubRow(next[i], incoming);
        replaced = true;
        break;
      }
      if (!replaced) next.add(incoming);
      // FC cold paint prefers SQLite warm list — keep RAM mirror in sync.
      if (!isTg && threadId != null) {
        _upsertWarmedFcThread(incoming);
      }
    }

    next.sort(_compareHubActivityDesc);
    await write(
      rows: next.take(maxRows).toList(),
      profileAvatarUrl: current?.profileAvatarUrl,
      profileAvatarSourcePath: current?.profileAvatarPath,
    );
  }

  /// After a full hub HTTP sync — keep in-RAM FC warm list aligned with SQLite.
  static void replaceWarmedFcThreads(List<Map<String, dynamic>> threads) {
    if (kIsWeb) return;
    _warmedFcThreads = [
      for (final t in threads) Map<String, dynamic>.from(t),
    ];
  }

  static void _upsertWarmedFcThread(Map<String, dynamic> thread) {
    final id = chatAsInt(thread['id']);
    if (id == null) return;
    final copy = Map<String, dynamic>.from(thread);
    final list = _warmedFcThreads;
    if (list == null) {
      _warmedFcThreads = [copy];
      return;
    }
    final next = <Map<String, dynamic>>[];
    var found = false;
    for (final t in list) {
      if (chatAsInt(t['id']) == id) {
        next.add(copy);
        found = true;
      } else {
        next.add(t);
      }
    }
    if (!found) next.insert(0, copy);
    next.sort(_compareHubActivityDesc);
    _warmedFcThreads = next;
  }

  static int? _linkedTgChatId(Map<String, dynamic> row) {
    final top = chatAsInt(row['tdlib_chat_id']);
    if (top != null && top != 0) return top;
    final tg = row['telegram'];
    if (tg is! Map) return null;
    return chatAsInt(tg['tg_chat_id']) ?? chatAsInt(tg['chat_id']);
  }

  static bool _isTgSyntheticKind(String kind) =>
      kind == 'tdlib_dm' ||
      kind == 'tdlib_chat' ||
      kind == 'tdlib_archive_chat';

  static bool _rowMatchesFull(
    Map<String, dynamic> row, {
    int? threadId,
    int? tdlibChatId,
  }) {
    if (threadId != null) {
      final kind = row['kind']?.toString() ?? '';
      if (!_isTgSyntheticKind(kind)) {
        return chatAsInt(row['id']) == threadId;
      }
    }
    if (tdlibChatId != null) {
      if (_linkedTgChatId(row) == tdlibChatId) return true;
      final top = chatAsInt(row['tdlib_chat_id']);
      if (top == tdlibChatId) return true;
    }
    return false;
  }

  /// Prefer keeping FC / tdlib_dm identity; refresh preview fields from [incoming].
  static Map<String, dynamic> _mergeFullHubRow(
    Map<String, dynamic> existing,
    Map<String, dynamic> incoming,
  ) {
    final existingKind = existing['kind']?.toString() ?? '';
    final incomingKind = incoming['kind']?.toString() ?? '';
    final existingIsFc = !_isTgSyntheticKind(existingKind);
    final incomingIsTg = _isTgSyntheticKind(incomingKind);

    // FC row owned by local-first: merge TG tip into FC shell when linked.
    if (existingIsFc && incomingIsTg) {
      final out = Map<String, dynamic>.from(existing);
      if (incoming.containsKey('unread_count')) {
        out['unread_count'] = incoming['unread_count'];
      }
      if (incoming.containsKey('notifications_enabled')) {
        out['notifications_enabled'] = incoming['notifications_enabled'];
      }
      final lmIn = incoming['last_message'];
      if (lmIn is Map) {
        final prev = out['last_message'];
        final lm = prev is Map
            ? Map<String, dynamic>.from(prev)
            : <String, dynamic>{};
        final body = lmIn['body']?.toString();
        if (body != null) lm['body'] = body;
        final created = lmIn['created_at']?.toString();
        if (created != null && created.isNotEmpty) {
          lm['created_at'] = created;
        }
        if (lmIn.containsKey('read_status')) {
          lm['read_status'] = lmIn['read_status'];
        }
        if (lmIn.containsKey('is_mine')) {
          lm['is_mine'] = lmIn['is_mine'];
        }
        out['last_message'] = lm;
      }
      final title = incoming['title']?.toString().trim();
      if (title != null && title.isNotEmpty) {
        // Do not overwrite FC custom titles with TG title.
        if ((out['custom_title']?.toString() ?? '').trim().isEmpty) {
          out['title'] = title;
        }
      }
      return out;
    }

    if (incomingIsTg && _isTgSyntheticKind(existingKind)) {
      final out = Map<String, dynamic>.from(incoming);
      out['id'] = existing['id'];
      // Keep dm/chat kind; archive membership is the flag.
      out['kind'] = existingKind == 'tdlib_archive_chat'
          ? 'tdlib_chat'
          : existingKind;
      if (incoming.containsKey('tdlib_archived')) {
        out['tdlib_archived'] = incoming['tdlib_archived'] == true;
      } else if (existing.containsKey('tdlib_archived')) {
        out['tdlib_archived'] = existing['tdlib_archived'] == true;
      }
      for (final key in [
        'peer_user_id',
        'peer_avatar_url',
        'telegram',
        'tdlib_user_id',
      ]) {
        if (out[key] == null && existing[key] != null) {
          out[key] = existing[key];
        }
      }
      return out;
    }

    // Same-side full replace (FC←FC or TG←TG insert path).
    final out = Map<String, dynamic>.from(incoming);
    if (incomingIsTg && out['kind']?.toString() == 'tdlib_archive_chat') {
      out['kind'] = 'tdlib_chat';
      out['tdlib_archived'] = true;
    }
    return out;
  }

  static int _compareHubActivityDesc(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    return _hubActivityMs(b).compareTo(_hubActivityMs(a));
  }

  static int _hubActivityMs(Map<String, dynamic> row) {
    final lm = row['last_message'];
    if (lm is Map) {
      final raw = lm['created_at']?.toString();
      final dt = DateTime.tryParse(raw ?? '');
      if (dt != null) return dt.millisecondsSinceEpoch;
      final date = (lm['date'] as num?)?.toInt();
      if (date != null && date > 0) {
        return date > 1e12 ? date : date * 1000;
      }
    }
    return 0;
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
      final isTg = _isTgSyntheticKind(kind);
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
    await write(
      rows: next.take(maxRows).toList(),
      profileAvatarUrl: current.profileAvatarUrl,
      profileAvatarSourcePath: current.profileAvatarPath,
    );
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
