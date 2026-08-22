import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../cache/familychat_local_cache.dart';
import 'gallery_media_utils.dart';
import 'local_device_file.dart';
import 'media_local_index.dart';

/// Локальное состояние фото галереи: пути, asset_id, превью без сети.
abstract final class GalleryPhotoLocalState {
  static int? photoId(Map<String, dynamic> photo) {
    final id = photo['id'];
    return id is int ? id : int.tryParse('$id');
  }

  static int? threadIdOf(Map<String, dynamic> photo) {
    final raw = photo['thread_id'];
    return raw is int ? raw : int.tryParse('$raw');
  }

  static Future<void> ensureLoaded() => MediaLocalIndex.ensureLoaded();

  static void applyIndex(Map<String, dynamic> photo) {
    MediaLocalIndex.hydrateAttachment(photo);
  }

  static void mergeFromPrevious(
    Map<String, dynamic> photo,
    Map<String, dynamic>? previous,
  ) {
    if (previous == null) return;
    for (final key in const [
      'local_bytes',
      'local_device_path',
      'local_asset_id',
      'local_media_kind',
      '_outgoing_original',
    ]) {
      if (isSafeUiPreviewBytes(photo['local_bytes']) &&
          key == 'local_bytes') {
        continue;
      }
      final current = photo[key];
      if (current != null && '$current'.trim().isNotEmpty) continue;
      final value = previous[key];
      if (value == null) continue;
      if (key == 'local_device_path') {
        final path = '$value'.trim();
        if (path.isEmpty || !localDeviceFileExists(path)) continue;
      }
      photo[key] = value;
    }
  }

  static Uint8List? previewBytesOf(Map<String, dynamic> photo) {
    return safeUiPreviewBytes(
      thumbnailBytes: photo['thumbnail_bytes'] is Uint8List
          ? photo['thumbnail_bytes'] as Uint8List
          : null,
      bytes: photo['local_bytes'] is Uint8List
          ? photo['local_bytes'] as Uint8List
          : null,
      kind: photo['kind']?.toString() ?? 'image',
    );
  }

  static Future<void> hydratePreviewBytes(Map<String, dynamic> photo) async {
    if (previewBytesOf(photo) != null) {
      final preview = previewBytesOf(photo)!;
      photo['local_bytes'] ??= preview;
      return;
    }

    final threadId = threadIdOf(photo);
    final id = photoId(photo);
    if (threadId != null && id != null) {
      final cached = await FamilyChatLocalCache.readAttachmentBytes(
        threadId,
        id,
      );
      if (cached != null && isSafeUiPreviewBytes(cached)) {
        photo['local_bytes'] = cached;
        return;
      }
    }

    await hydrateFromAsset(photo);
  }

  static Future<void> hydratePreviewBytesBatch(
    List<Map<String, dynamic>> photos, {
    int concurrency = 10,
  }) async {
    if (photos.isEmpty) return;
    for (var i = 0; i < photos.length; i += concurrency) {
      final end = (i + concurrency).clamp(0, photos.length);
      final chunk = photos.sublist(i, end);
      await Future.wait(chunk.map(hydratePreviewBytes));
    }
  }

  static Future<void> hydrateFromAsset(Map<String, dynamic> photo) async {
    if (kIsWeb) return;
    if (previewBytesOf(photo) != null) return;

    final assetId = photo['local_asset_id']?.toString().trim() ?? '';
    if (assetId.isEmpty) return;

    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) return;
      final thumb = await entity.thumbnailDataWithSize(
        const ThumbnailSize(360, 360),
      );
      if (thumb != null && isSafeUiPreviewBytes(thumb)) {
        photo['local_bytes'] = thumb;
      }
    } catch (e) {
      debugPrint('[GalleryPhotoLocalState] asset thumb failed: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> indexPhotos(
    List<Map<String, dynamic>> photos, {
    List<Map<String, dynamic>>? previous,
  }) async {
    await ensureLoaded();
    final prevById = <int, Map<String, dynamic>>{};
    for (final p in previous ?? const <Map<String, dynamic>>[]) {
      final id = photoId(p);
      if (id != null) prevById[id] = p;
    }

    final enriched = <Map<String, dynamic>>[];
    for (final raw in photos) {
      final photo = Map<String, dynamic>.from(raw);
      applyIndex(photo);
      final id = photoId(photo);
      if (id != null) {
        mergeFromPrevious(photo, prevById[id]);
      }
      enriched.add(photo);
    }
    return enriched;
  }

  /// Полное обогащение: индекс + превью (может быть медленным — не блокировать UI).
  static Future<List<Map<String, dynamic>>> enrichPhotos(
    List<Map<String, dynamic>> photos, {
    List<Map<String, dynamic>>? previous,
  }) async {
    final enriched = await indexPhotos(photos, previous: previous);
    await hydratePreviewBytesBatch(enriched);
    return enriched;
  }

  static Future<void> persistOutgoing({
    required Map<String, dynamic> uploaded,
    required String filename,
    required String kind,
    String? localPath,
    String? assetId,
    Uint8List? previewBytes,
  }) async {
    final id = photoId(uploaded);
    if (id == null) return;

    final path = localPath?.trim() ?? '';
    final asset = assetId?.trim() ?? '';
    if (path.isNotEmpty || asset.isNotEmpty) {
      await MediaLocalIndex.saveOutgoing(
        attachmentId: id,
        localPath: path,
        filename: filename,
        kind: kind,
        assetId: asset.isEmpty ? null : asset,
      );
    }

    if (path.isNotEmpty && localDeviceFileExists(path)) {
      uploaded['local_device_path'] = path;
    }
    if (asset.isNotEmpty) {
      uploaded['local_asset_id'] = asset;
    }
    uploaded['_outgoing_original'] = true;

    final preview = previewBytes ?? previewBytesOf(uploaded);
    if (preview != null && isSafeUiPreviewBytes(preview)) {
      uploaded['local_bytes'] = preview;
      final threadId = threadIdOf(uploaded);
      if (threadId != null) {
        unawaited(
          FamilyChatLocalCache.saveAttachmentBytes(threadId, id, preview),
        );
      }
    }

    applyIndex(uploaded);
  }
}
