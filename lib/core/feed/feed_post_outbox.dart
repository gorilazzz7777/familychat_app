import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/shell_refresh.dart';
import '../../features/familychat/data/familychat_repository.dart';
import '../../features/feed/data/feed_post_uploader.dart';
import '../media/gallery_photo_local_state.dart';
import '../media/media_upload_foreground.dart';
import 'feed_post_local_store.dart';

/// Локальная очередь публикации постов в ленту.
///
/// Статус `synced` ставится только после подтверждения сервера
/// (`created` или `already_finalized`).
class FeedPostOutbox {
  FeedPostOutbox._();
  static final FeedPostOutbox instance = FeedPostOutbox._();

  static const _prefsKey = 'fc_feed_post_outbox_v1';
  static const maxAttempts = 12;

  bool _flushing = false;

  Future<List<FeedPostOutboxEntry>> listPending() async {
    final all = await _readAll();
    return all.where((e) => e.status != FeedPostOutboxStatus.synced).toList();
  }

  Future<FeedPostOutboxEntry> enqueue({
    required String batchId,
    required List<FeedPostPhoto> photos,
    required String caption,
    required bool shareToDiary,
    int? childId,
    int? optimisticId,
  }) async {
    final localId = 'fp_${DateTime.now().microsecondsSinceEpoch}';
    final items = <FeedPostOutboxPhoto>[];
    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      final cacheId = (photo.cacheId != null && photo.cacheId!.isNotEmpty)
          ? photo.cacheId!
          : '${localId}_$i';
      final path = await FeedPostLocalStore.store(
        id: cacheId,
        bytes: photo.bytes,
        filename: photo.filename,
      );
      items.add(
        FeedPostOutboxPhoto(
          cacheId: cacheId,
          filename: photo.filename,
          contentType: photo.contentType,
          kind: photo.kind,
          localPath: photo.localPath,
          storagePath: path,
          photoExif: photo.photoExif,
          assetId: photo.assetId,
          assetFingerprint: photo.assetFingerprint,
        ),
      );
    }

    final entry = FeedPostOutboxEntry(
      localId: localId,
      batchId: batchId,
      caption: caption,
      shareToDiary: shareToDiary,
      childId: childId,
      optimisticId: optimisticId,
      status: FeedPostOutboxStatus.pending,
      photos: items,
      createdAt: DateTime.now().toUtc(),
      attempts: 0,
    );
    final all = await _readAll();
    all.removeWhere((e) => e.localId == localId);
    all.add(entry);
    await _writeAll(all);
    return entry;
  }

  Future<void> markSynced({
    required String localId,
    int? serverEventId,
  }) async {
    final all = await _readAll();
    final idx = all.indexWhere((e) => e.localId == localId);
    if (idx < 0) return;
    final prev = all[idx];
    all[idx] = prev.copyWith(
      status: FeedPostOutboxStatus.synced,
      serverEventId: serverEventId ?? prev.serverEventId,
      syncedAt: DateTime.now().toUtc(),
    );
    await _writeAll(all);
    for (final photo in prev.photos) {
      await FeedPostLocalStore.delete(photo.storagePath);
    }
  }

  Future<void> flush(FamilyChatRepository repo) async {
    if (_flushing) return;
    _flushing = true;
    await MediaUploadForeground.enter(MediaUploadForeground.scopeFeed);
    try {
      final pending = await listPending();
      var anySynced = false;
      for (final entry in pending) {
        final ok = await _syncOne(repo, entry);
        if (ok) anySynced = true;
      }
      if (anySynced) {
        await ShellRefresh.instance.refreshMainTabs();
      }
    } finally {
      _flushing = false;
      await MediaUploadForeground.leave(MediaUploadForeground.scopeFeed);
    }
  }

  Future<bool> _syncOne(
    FamilyChatRepository repo,
    FeedPostOutboxEntry entry,
  ) async {
    if (entry.attempts >= maxAttempts) return false;

    var current = entry.copyWith(
      status: FeedPostOutboxStatus.uploading,
      attempts: entry.attempts + 1,
      lastAttemptAt: DateTime.now().toUtc(),
    );
    await _upsert(current);

    try {
      final uploaded = Map<String, int>.from(current.uploadedAttachmentIds);
      for (final photo in current.photos) {
        if (uploaded.containsKey(photo.cacheId)) continue;
        final bytes = await FeedPostLocalStore.read(photo.storagePath);
        if (bytes == null || bytes.isEmpty) continue;
        final Map<String, dynamic> res;
        if (current.childId != null) {
          res = await repo.childGalleryUpload(
            childId: current.childId!,
            bytes: bytes,
            filename: photo.filename,
            contentType: photo.contentType,
            batchId: current.batchId,
            photoExif: photo.photoExif,
          );
        } else {
          res = await repo.familyGalleryUpload(
            bytes: bytes,
            filename: photo.filename,
            contentType: photo.contentType,
            destination: 'family_feed',
            batchId: current.batchId,
            shareToDiary: current.shareToDiary,
            photoExif: photo.photoExif,
          );
        }
        final id = res['id'] is int
            ? res['id'] as int
            : int.tryParse('${res['id']}');
        if (id != null) {
          uploaded[photo.cacheId] = id;
          current = current.copyWith(uploadedAttachmentIds: uploaded);
          await _upsert(current);
          unawaited(
            GalleryPhotoLocalState.persistOutgoing(
              uploaded: res,
              filename: photo.filename,
              kind: photo.kind,
              localPath: photo.localPath,
              assetId: photo.assetId,
              assetFingerprint: photo.assetFingerprint,
            ),
          );
        }
      }

      current = current.copyWith(status: FeedPostOutboxStatus.completing);
      await _upsert(current);

      for (var attempt = 0; attempt < 5; attempt++) {
        final result = await repo.completeFeedPhotoBatch(
          current.batchId,
          caption: current.caption.isEmpty ? null : current.caption,
          shareToDiary:
              current.childId == null ? current.shareToDiary : false,
        );
        final created = result['created'] == true;
        final already = result['already_finalized'] == true;
        final event = result['event'];
        int? eventId;
        if (event is Map) {
          final raw = event['id'];
          eventId = raw is int ? raw : int.tryParse('$raw');
        }
        if (created || already) {
          await markSynced(localId: current.localId, serverEventId: eventId);
          return true;
        }
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }

      current = current.copyWith(status: FeedPostOutboxStatus.pending);
      await _upsert(current);
      return false;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[FeedPostOutbox] sync failed ${current.localId}: $e\n$st');
      }
      current = current.copyWith(status: FeedPostOutboxStatus.pending);
      await _upsert(current);
      return false;
    }
  }

  Future<void> _upsert(FeedPostOutboxEntry entry) async {
    final all = await _readAll();
    final idx = all.indexWhere((e) => e.localId == entry.localId);
    if (idx >= 0) {
      all[idx] = entry;
    } else {
      all.add(entry);
    }
    await _writeAll(all);
  }

  Future<List<FeedPostOutboxEntry>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => FeedPostOutboxEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeAll(List<FeedPostOutboxEntry> entries) async {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 3));
    final kept = entries.where((e) {
      if (e.status != FeedPostOutboxStatus.synced) return true;
      final at = e.syncedAt;
      return at == null || at.isAfter(cutoff);
    }).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(kept.map((e) => e.toJson()).toList()),
    );
  }
}

enum FeedPostOutboxStatus {
  pending,
  uploading,
  completing,
  synced,
}

class FeedPostOutboxPhoto {
  const FeedPostOutboxPhoto({
    required this.cacheId,
    required this.filename,
    required this.kind,
    this.contentType,
    this.localPath,
    this.storagePath,
    this.photoExif,
    this.assetId,
    this.assetFingerprint,
  });

  final String cacheId;
  final String filename;
  final String kind;
  final String? contentType;
  final String? localPath;
  final String? storagePath;
  final Map<String, dynamic>? photoExif;
  final String? assetId;
  final String? assetFingerprint;

  Map<String, dynamic> toJson() => {
        'cacheId': cacheId,
        'filename': filename,
        'kind': kind,
        if (contentType != null) 'contentType': contentType,
        if (localPath != null) 'localPath': localPath,
        if (storagePath != null) 'storagePath': storagePath,
        if (photoExif != null) 'photoExif': photoExif,
        if (assetId != null) 'assetId': assetId,
        if (assetFingerprint != null) 'assetFingerprint': assetFingerprint,
      };

  factory FeedPostOutboxPhoto.fromJson(Map<String, dynamic> json) {
    return FeedPostOutboxPhoto(
      cacheId: json['cacheId']?.toString() ?? '',
      filename: json['filename']?.toString() ?? 'photo.jpg',
      kind: json['kind']?.toString() ?? 'image',
      contentType: json['contentType']?.toString(),
      localPath: json['localPath']?.toString(),
      storagePath: json['storagePath']?.toString(),
      photoExif: json['photoExif'] is Map
          ? Map<String, dynamic>.from(json['photoExif'] as Map)
          : null,
      assetId: json['assetId']?.toString(),
      assetFingerprint: json['assetFingerprint']?.toString(),
    );
  }
}

class FeedPostOutboxEntry {
  const FeedPostOutboxEntry({
    required this.localId,
    required this.batchId,
    required this.caption,
    required this.shareToDiary,
    required this.status,
    required this.photos,
    required this.createdAt,
    this.childId,
    this.optimisticId,
    this.uploadedAttachmentIds = const {},
    this.serverEventId,
    this.syncedAt,
    this.attempts = 0,
    this.lastAttemptAt,
  });

  final String localId;
  final String batchId;
  final String caption;
  final bool shareToDiary;
  final int? childId;
  final int? optimisticId;
  final FeedPostOutboxStatus status;
  final List<FeedPostOutboxPhoto> photos;
  final Map<String, int> uploadedAttachmentIds;
  final int? serverEventId;
  final DateTime createdAt;
  final DateTime? syncedAt;
  final int attempts;
  final DateTime? lastAttemptAt;

  FeedPostOutboxEntry copyWith({
    FeedPostOutboxStatus? status,
    Map<String, int>? uploadedAttachmentIds,
    int? serverEventId,
    DateTime? syncedAt,
    int? attempts,
    DateTime? lastAttemptAt,
  }) {
    return FeedPostOutboxEntry(
      localId: localId,
      batchId: batchId,
      caption: caption,
      shareToDiary: shareToDiary,
      childId: childId,
      optimisticId: optimisticId,
      status: status ?? this.status,
      photos: photos,
      uploadedAttachmentIds:
          uploadedAttachmentIds ?? this.uploadedAttachmentIds,
      serverEventId: serverEventId ?? this.serverEventId,
      createdAt: createdAt,
      syncedAt: syncedAt ?? this.syncedAt,
      attempts: attempts ?? this.attempts,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'localId': localId,
        'batchId': batchId,
        'caption': caption,
        'shareToDiary': shareToDiary,
        if (childId != null) 'childId': childId,
        if (optimisticId != null) 'optimisticId': optimisticId,
        'status': status.name,
        'photos': photos.map((e) => e.toJson()).toList(),
        'uploadedAttachmentIds': uploadedAttachmentIds,
        if (serverEventId != null) 'serverEventId': serverEventId,
        'createdAt': createdAt.toIso8601String(),
        if (syncedAt != null) 'syncedAt': syncedAt!.toIso8601String(),
        'attempts': attempts,
        if (lastAttemptAt != null)
          'lastAttemptAt': lastAttemptAt!.toIso8601String(),
      };

  factory FeedPostOutboxEntry.fromJson(Map<String, dynamic> json) {
    final photosRaw = json['photos'];
    final uploadedRaw = json['uploadedAttachmentIds'];
    final uploaded = <String, int>{};
    if (uploadedRaw is Map) {
      for (final e in uploadedRaw.entries) {
        final id = e.value is int ? e.value as int : int.tryParse('${e.value}');
        if (id != null) uploaded['${e.key}'] = id;
      }
    }
    return FeedPostOutboxEntry(
      localId: json['localId']?.toString() ?? '',
      batchId: json['batchId']?.toString() ?? '',
      caption: json['caption']?.toString() ?? '',
      shareToDiary: json['shareToDiary'] == true,
      childId: json['childId'] is int
          ? json['childId'] as int
          : int.tryParse('${json['childId']}'),
      optimisticId: json['optimisticId'] is int
          ? json['optimisticId'] as int
          : int.tryParse('${json['optimisticId']}'),
      status: FeedPostOutboxStatus.values.firstWhere(
        (s) => s.name == json['status']?.toString(),
        orElse: () => FeedPostOutboxStatus.pending,
      ),
      photos: photosRaw is List
          ? photosRaw
              .whereType<Map>()
              .map(
                (e) => FeedPostOutboxPhoto.fromJson(
                  Map<String, dynamic>.from(e),
                ),
              )
              .toList()
          : const [],
      uploadedAttachmentIds: uploaded,
      serverEventId: json['serverEventId'] is int
          ? json['serverEventId'] as int
          : int.tryParse('${json['serverEventId']}'),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '')
              ?.toUtc() ??
          DateTime.now().toUtc(),
      syncedAt:
          DateTime.tryParse(json['syncedAt']?.toString() ?? '')?.toUtc(),
      attempts: json['attempts'] is int
          ? json['attempts'] as int
          : int.tryParse('${json['attempts']}') ?? 0,
      lastAttemptAt:
          DateTime.tryParse(json['lastAttemptAt']?.toString() ?? '')?.toUtc(),
    );
  }
}
