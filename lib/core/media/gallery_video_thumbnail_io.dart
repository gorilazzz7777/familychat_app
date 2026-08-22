import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'gallery_device_media_store.dart';
import 'gallery_media_utils.dart';

/// Локальный JPEG-кадр для превью видео в сетке / обложках альбомов.
abstract final class GalleryVideoThumbnail {
  static final Map<String, Future<String?>> _inflight = {};
  static Directory? _cacheDir;
  static const _maxConcurrent = 2;
  static int _active = 0;
  static final List<Completer<void>> _waiters = [];

  static Future<void> _acquireSlot() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  static void _releaseSlot() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _active = (_active - 1).clamp(0, _maxConcurrent);
  }

  static Future<Directory> _dir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/familychat_video_thumbs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  static String _cacheKey(Map<String, dynamic> attachment) {
    final id = attachment['id']?.toString() ?? '';
    final url = galleryAttachmentUrl(attachment);
    final local = GalleryDeviceMediaStore.existingLocalPath(attachment) ?? '';
    return '${id}_${url.hashCode}_${local.hashCode}';
  }

  static Future<String?> ensureForAttachment(
    Map<String, dynamic> attachment, {
    int maxWidth = 512,
    int timeMs = 500,
  }) async {
    if (kIsWeb || !isVideoAttachment(attachment)) return null;

    final explicit =
        attachment['local_video_thumb_path']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) {
      try {
        if (File(explicit).existsSync()) return explicit;
      } catch (_) {}
    }

    final key = _cacheKey(attachment);
    final existing = _inflight[key];
    if (existing != null) return existing;

    final future = _withSlot(
      () => _generate(
        attachment,
        maxWidth: maxWidth,
        timeMs: timeMs,
      ),
    );
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<String?> _withSlot(Future<String?> Function() fn) async {
    await _acquireSlot();
    try {
      return await fn();
    } finally {
      _releaseSlot();
    }
  }

  static Future<String?> _generate(
    Map<String, dynamic> attachment, {
    required int maxWidth,
    required int timeMs,
  }) async {
    try {
      final dir = await _dir();
      final key = _cacheKey(attachment);
      final outPath = '${dir.path}/$key.jpg';
      final cached = File(outPath);
      if (await cached.exists() && await cached.length() > 0) {
        return outPath;
      }

      final assetId = attachment['local_asset_id']?.toString().trim() ?? '';
      if (assetId.isNotEmpty) {
        try {
          final entity = await AssetEntity.fromId(assetId);
          final bytes = await entity?.thumbnailDataWithSize(
            const ThumbnailSize(512, 512),
            quality: 80,
          );
          if (bytes != null && bytes.isNotEmpty) {
            await cached.writeAsBytes(bytes, flush: true);
            return outPath;
          }
        } catch (_) {}
      }

      final local = GalleryDeviceMediaStore.existingLocalPath(attachment);
      if (local == null || local.isEmpty) {
        // Без локального файла не качаем видео с S3 ради кадра — ждём thumbnail_url.
        return null;
      }
      final source = local;

      final generated = await VideoThumbnail.thumbnailFile(
        video: source,
        thumbnailPath: outPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: maxWidth,
        timeMs: timeMs,
        quality: 75,
      );
      if (generated == null || generated.isEmpty) return null;
      final file = File(generated);
      if (!await file.exists() || await file.length() == 0) return null;
      if (file.path != outPath) {
        await file.copy(outPath);
      }
      return outPath;
    } catch (e, st) {
      debugPrint('[GalleryVideoThumbnail] failed: $e\n$st');
      return null;
    }
  }
}
