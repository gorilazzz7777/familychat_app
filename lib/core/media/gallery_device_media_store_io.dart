import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../cache/familychat_media_cache.dart';
import 'gallery_media_export.dart';
import 'gallery_media_utils.dart';
import 'local_device_file.dart';

class LocalMediaRef {
  const LocalMediaRef({
    required this.path,
    this.assetId,
    required this.kind,
    required this.serverUrl,
  });

  final String path;
  final String? assetId;
  final String kind;
  final String serverUrl;

  Map<String, dynamic> toPayloadFields() => {
        'local_device_path': path,
        if (assetId != null && assetId!.isNotEmpty) 'local_asset_id': assetId,
        'local_media_kind': kind,
        'server_url': serverUrl,
      };
}

/// Скачать чужое медиа и сохранить в Pictures/FamilyChat.
/// Свои файлы сюда не копируем — для них хранится исходный local_device_path.
abstract final class GalleryDeviceMediaStore {
  static const albumName = GalleryMediaExport.appAlbumName;

  static final Map<String, Future<LocalMediaRef?>> _inflight = {};

  static String? existingLocalPath(Map<String, dynamic> attachment) {
    final path = attachment['local_device_path']?.toString().trim() ?? '';
    if (path.isEmpty) return null;
    return localDeviceFileExists(path) ? path : null;
  }

  static bool isGalleryMedia(Map<String, dynamic> attachment) =>
      isImageAttachment(attachment) || isVideoAttachment(attachment);

  /// Уже лежит в Pictures/FamilyChat или LittleOne — путь без повторного save.
  static Future<Map<String, dynamic>?> linkExistingInAlbum(
    Map<String, dynamic> attachment,
  ) async {
    if (kIsWeb) return null;
    final filename = GalleryMediaExport.filenameFor(attachment);
    if (filename.trim().isEmpty) return null;
    try {
      final existing = await GalleryMediaExport.findExistingInAppAlbum(filename);
      if (existing == null) return null;
      File? file;
      try {
        file = await existing.originFile;
      } catch (_) {}
      file ??= await existing.file;
      if (file == null || !await file.exists()) return null;
      final url = galleryAttachmentUrl(attachment);
      return {
        'local_device_path': file.path,
        'local_asset_id': existing.id,
        'local_media_kind': isVideoAttachment(attachment) ? 'video' : 'image',
        if (url.isNotEmpty) 'server_url': url,
      };
    } catch (e) {
      debugPrint('[GalleryDeviceMediaStore] linkExisting failed: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> ensureForAttachment(
    Map<String, dynamic> attachment, {
    String? albumId,
    bool downloadVideo = true,
    bool allowCopyToPhoneAlbum = true,
  }) async {
    if (kIsWeb) return null;
    final existing = existingLocalPath(attachment);
    final url = galleryAttachmentUrl(attachment);
    if (existing != null) {
      return {
        'local_device_path': existing,
        'local_asset_id': attachment['local_asset_id'],
        'local_media_kind': isVideoAttachment(attachment) ? 'video' : 'image',
        if (url.isNotEmpty) 'server_url': url,
      };
    }
    // Сначала ищем локальную копию в FamilyChat / LittleOne (Dairy).
    final linked = await linkExistingInAlbum(attachment);
    if (linked != null) return linked;

    final video = isVideoAttachment(attachment);
    if (video && !downloadVideo) return null;
    if (url.isEmpty) return null;
    final id = attachment['id']?.toString() ?? url.hashCode.toString();
    final ref = await ensureLocalMedia(
      serverUrl: url,
      mediaId: id,
      albumId: albumId ?? attachment['_album_id']?.toString(),
      isVideo: video,
      filename: GalleryMediaExport.filenameFor(attachment),
      allowCopyToPhoneAlbum: allowCopyToPhoneAlbum,
    );
    return ref?.toPayloadFields();
  }

  static Future<LocalMediaRef?> ensureLocalMedia({
    required String serverUrl,
    required String mediaId,
    String? albumId,
    bool isVideo = false,
    String? filename,
    bool allowCopyToPhoneAlbum = true,
  }) async {
    if (kIsWeb) return null;
    final url = serverUrl.trim();
    if (url.isEmpty) return null;

    final key = '$mediaId:$isVideo:$url:$allowCopyToPhoneAlbum';
    final existing = _inflight[key];
    if (existing != null) return existing;

    final future = _ensureLocalMediaImpl(
      serverUrl: url,
      mediaId: mediaId,
      albumId: albumId,
      isVideo: isVideo,
      filename: filename,
      allowCopyToPhoneAlbum: allowCopyToPhoneAlbum,
    );
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<LocalMediaRef?> _ensureLocalMediaImpl({
    required String serverUrl,
    required String mediaId,
    String? albumId,
    required bool isVideo,
    String? filename,
    bool allowCopyToPhoneAlbum = true,
  }) async {
    try {
      final name = filename?.trim().isNotEmpty == true
          ? filename!.trim()
          : (isVideo
              ? 'video_${mediaId}_${serverUrl.hashCode.abs()}.mp4'
              : 'photo_${mediaId}_${serverUrl.hashCode.abs()}.jpg');

      File? source = await GalleryMediaExport.fileFromDiskCache(serverUrl);
      if (source == null) {
        try {
          final manager = isVideo
              ? FamilyChatMediaCache.fullscreen
              : FamilyChatMediaCache.preview;
          source = await manager.getSingleFile(serverUrl);
        } catch (_) {
          try {
            source = await DefaultCacheManager().getSingleFile(serverUrl);
          } catch (_) {
            source = null;
          }
        }
      }
      if (source == null || !await source.exists() || await source.length() == 0) {
        return null;
      }

      if (allowCopyToPhoneAlbum) {
        final galleryRef = await _trySaveToPhoneGallery(
          source: source,
          filename: name,
          isVideo: isVideo,
          serverUrl: serverUrl,
        );
        if (galleryRef != null) return galleryRef;
      }

      return _saveToAppSupport(
        source: source,
        filename: name,
        isVideo: isVideo,
        serverUrl: serverUrl,
        mediaId: mediaId,
        albumId: albumId,
      );
    } catch (e, st) {
      debugPrint('[GalleryDeviceMediaStore] ensure failed: $e\n$st');
      return null;
    }
  }

  static Future<LocalMediaRef?> _trySaveToPhoneGallery({
    required File source,
    required String filename,
    required bool isVideo,
    required String serverUrl,
  }) async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) return null;

      final existing = await GalleryMediaExport.findExistingInAppAlbum(filename);
      if (existing != null) {
        final reused = await _refFromAsset(
          existing,
          isVideo: isVideo,
          serverUrl: serverUrl,
          filename: filename,
          source: source,
        );
        if (reused != null) return reused;
      }

      AssetEntity entity;
      if (isVideo) {
        try {
          entity = await PhotoManager.editor.saveVideo(
            source,
            title: filename,
            relativePath: 'Pictures/$albumName',
          );
        } catch (_) {
          entity = await PhotoManager.editor.saveVideo(
            source,
            title: filename,
          );
        }
      } else {
        final bytes = await source.readAsBytes();
        try {
          entity = await PhotoManager.editor.saveImage(
            bytes,
            filename: filename,
            title: filename,
            relativePath: 'Pictures/$albumName',
          );
        } catch (_) {
          entity = await PhotoManager.editor.saveImage(
            bytes,
            filename: filename,
            title: filename,
          );
        }
      }
      await GalleryMediaExport.tryAddToIosAlbum(entity);
      GalleryMediaExport.rememberAppAlbumAsset(filename, entity.id);

      return _refFromAsset(
        entity,
        isVideo: isVideo,
        serverUrl: serverUrl,
        filename: filename,
        source: source,
      );
    } catch (e) {
      debugPrint('[GalleryDeviceMediaStore] gallery save failed: $e');
      return null;
    }
  }

  static Future<LocalMediaRef?> _refFromAsset(
    AssetEntity entity, {
    required bool isVideo,
    required String serverUrl,
    required String filename,
    required File source,
  }) async {
    File? file;
    try {
      file = await entity.originFile;
    } catch (_) {}
    file ??= await entity.file;
    if (file != null && await file.exists()) {
      return LocalMediaRef(
        path: file.path,
        assetId: entity.id,
        kind: isVideo ? 'video' : 'image',
        serverUrl: serverUrl,
      );
    }

    final support = await _saveToAppSupport(
      source: source,
      filename: filename,
      isVideo: isVideo,
      serverUrl: serverUrl,
      mediaId: entity.id,
      albumId: null,
    );
    if (support == null) return null;
    return LocalMediaRef(
      path: support.path,
      assetId: entity.id,
      kind: isVideo ? 'video' : 'image',
      serverUrl: serverUrl,
    );
  }

  static Future<LocalMediaRef?> _saveToAppSupport({
    required File source,
    required String filename,
    required bool isVideo,
    required String serverUrl,
    required String mediaId,
    String? albumId,
  }) async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/familychat_device_media');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final safe = filename.replaceAll(RegExp(r'[^\w.\-]+'), '_');
      final prefix = [
        if (albumId != null && albumId.isNotEmpty) albumId,
        mediaId,
      ].join('_');
      final out = File('${dir.path}/${prefix}_$safe');
      if (!await out.exists() || await out.length() == 0) {
        await source.copy(out.path);
      }
      return LocalMediaRef(
        path: out.path,
        assetId: null,
        kind: isVideo ? 'video' : 'image',
        serverUrl: serverUrl,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteFromPhoneAlbum({
    String? assetId,
    String? filename,
  }) async {
    if (kIsWeb) return;
    try {
      final ids = <String>[];
      final known = assetId?.trim() ?? '';
      if (known.isNotEmpty) ids.add(known);
      final name = filename?.trim() ?? '';
      if (name.isNotEmpty) {
        final existing = await GalleryMediaExport.findExistingInAppAlbum(name);
        if (existing != null && !ids.contains(existing.id)) {
          ids.add(existing.id);
        }
      }
      if (ids.isEmpty) return;
      await PhotoManager.editor.deleteWithIds(ids);
    } catch (e) {
      debugPrint('[GalleryDeviceMediaStore] delete failed: $e');
    }
  }
}
