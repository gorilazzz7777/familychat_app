import 'dart:async';

import 'package:flutter/foundation.dart';

import '../cache/familychat_media_cache.dart';
import 'gallery_device_media_store.dart';
import 'gallery_media_export.dart';
import 'gallery_media_utils.dart';
import 'local_device_file.dart';
import 'media_cache_policy.dart';
import 'media_local_index.dart';

/// Фоновая синхронизация чужих фото/видео в альбом FamilyChat.
///
/// По умолчанию выключено (настройка «Сохранять входящие в Галерею»).
/// Свои оригиналы не копируем. «Скачать» на полном экране пишет в альбом явно.
abstract final class MediaIncomingSync {
  static final Set<String> _inflight = {};

  static Future<void> ensureMessages(
    Iterable<Map<String, dynamic>> messages,
  ) async {
    await MediaLocalIndex.ensureLoaded();
    for (final message in messages) {
      final rawMeta = message['metadata'];
      final metadata = rawMeta is Map
          ? Map<String, dynamic>.from(rawMeta)
          : null;
      if (messageHasKlipyMedia(metadata)) continue;

      final raw = message['attachments'];
      if (raw is! List) continue;
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          unawaited(ensureAttachment(item));
        } else if (item is Map) {
          unawaited(ensureAttachment(Map<String, dynamic>.from(item)));
        }
      }
    }
  }

  static Future<void> ensureFeedEvents(
    Iterable<Map<String, dynamic>> events,
  ) async {
    await MediaLocalIndex.ensureLoaded();
    for (final event in events) {
      MediaLocalIndex.hydrateFeedEvent(event);
      final payload = event['payload'];
      if (payload is! Map) continue;
      final atts = payload['attachments'];
      if (atts is! List) continue;
      for (final item in atts) {
        if (item is Map<String, dynamic>) {
          unawaited(ensureAttachment(item));
        } else if (item is Map) {
          unawaited(ensureAttachment(Map<String, dynamic>.from(item)));
        }
      }
    }
  }

  static Future<void> ensureGalleryPhotos(
    Iterable<Map<String, dynamic>> photos,
  ) async {
    await MediaLocalIndex.ensureLoaded();
    for (final photo in photos) {
      unawaited(ensureAttachment(photo));
    }
  }

  static Future<void> ensureAttachment(Map<String, dynamic> attachment) async {
    if (!isGalleryMediaAttachment(attachment)) return;
    await MediaLocalIndex.ensureLoaded();
    MediaLocalIndex.hydrateAttachment(attachment);

    final id = attachment['id'] is int
        ? attachment['id'] as int
        : int.tryParse('${attachment['id']}');
    final key = id != null
        ? MediaLocalIndex.keyForAttachmentId(id)
        : MediaLocalIndex.keyForFilename(
            GalleryMediaExport.filenameFor(attachment),
          );
    if (key.isEmpty) return;

    final rec = MediaLocalIndex.peek(key) ??
        MediaLocalIndex.peekByFilename(attachment['filename']?.toString());

    if (rec?.isOutgoing == true || attachment['_outgoing_original'] == true) {
      return;
    }
    if (!MediaCachePolicy.autoSaveIncomingToGallery) {
      return;
    }
    if (rec?.skipPhoneAlbum == true || attachment['skip_phone_album'] == true) {
      return;
    }

    final path = rec?.path?.trim() ??
        attachment['local_device_path']?.toString().trim() ??
        '';
    if (path.isNotEmpty) {
      if (localDeviceFileExists(path)) return;
      // Был путь, файла нет — пользователь удалил из галереи телефона.
      await MediaLocalIndex.markSkipPhoneAlbum(key);
      return;
    }

    if (kIsWeb) {
      await _ensureWebCache(attachment);
      return;
    }

    if (_inflight.contains(key)) return;
    _inflight.add(key);
    try {
      final fields = await GalleryDeviceMediaStore.ensureForAttachment(
        attachment,
        downloadVideo: true,
        allowCopyToPhoneAlbum: true,
      );
      if (fields == null || fields.isEmpty) return;
      await MediaLocalIndex.upsert(
        MediaLocalRecord(
          key: key,
          attachmentId: id,
          path: fields['local_device_path']?.toString(),
          assetId: fields['local_asset_id']?.toString(),
          kind: isVideoAttachment(attachment) ? 'video' : 'image',
          serverUrl: galleryAttachmentUrl(attachment),
          filename: GalleryMediaExport.filenameFor(attachment),
        ),
      );
    } catch (e) {
      debugPrint('[MediaIncomingSync] ensure failed: $e');
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<void> _ensureWebCache(Map<String, dynamic> attachment) async {
    final url = galleryAttachmentUrl(attachment);
    if (url.isEmpty) return;
    try {
      final isVideo = isVideoAttachment(attachment);
      final manager =
          isVideo ? FamilyChatMediaCache.fullscreen : FamilyChatMediaCache.preview;
      await manager.getSingleFile(url);
    } catch (_) {}
  }

  /// Кнопка «Скачать»: в Pictures/FamilyChat и локальные ссылки в индексе.
  static Future<void> saveByUserDownload(
    Map<String, dynamic> attachment, {
    Future<Uint8List> Function()? fetchBytes,
  }) async {
    await MediaLocalIndex.ensureLoaded();
    final id = attachment['id'] is int
        ? attachment['id'] as int
        : int.tryParse('${attachment['id']}');
    final key = id != null
        ? MediaLocalIndex.keyForAttachmentId(id)
        : MediaLocalIndex.keyForFilename(
            GalleryMediaExport.filenameFor(attachment),
          );
    if (key.isEmpty) return;

    attachment.remove('skip_phone_album');
    final stale = attachment['local_device_path']?.toString().trim() ?? '';
    if (stale.isNotEmpty && !localDeviceFileExists(stale)) {
      attachment.remove('local_device_path');
      attachment.remove('local_asset_id');
    }

    if (kIsWeb) {
      await _ensureWebCache(attachment);
      await MediaLocalIndex.upsert(
        MediaLocalRecord(
          key: key,
          attachmentId: id,
          kind: isVideoAttachment(attachment) ? 'video' : 'image',
          serverUrl: galleryAttachmentUrl(attachment),
          filename: GalleryMediaExport.filenameFor(attachment),
          skipPhoneAlbum: false,
        ),
      );
      return;
    }

    var fields = await GalleryDeviceMediaStore.linkExistingInAlbum(attachment);
    if (fields == null) {
      final previousPath = attachment['local_device_path'];
      final previousAsset = attachment['local_asset_id'];
      attachment.remove('local_device_path');
      attachment.remove('local_asset_id');
      try {
        fields = await GalleryDeviceMediaStore.ensureForAttachment(
          attachment,
          downloadVideo: true,
          allowCopyToPhoneAlbum: true,
        );
        if (fields == null && fetchBytes != null) {
          await GalleryMediaExport.saveAttachmentsToGallery(
            attachments: [attachment],
            fetchBytes: (_) => fetchBytes(),
          );
          fields = await GalleryDeviceMediaStore.linkExistingInAlbum(attachment);
        }
      } finally {
        if (fields == null) {
          if (previousPath != null) {
            attachment['local_device_path'] = previousPath;
          }
          if (previousAsset != null) {
            attachment['local_asset_id'] = previousAsset;
          }
        }
      }
    }
    if (fields == null) {
      throw StateError('Не удалось сохранить в «${GalleryMediaExport.appAlbumName}»');
    }

    _applyLocalFields(attachment, fields);
    await MediaLocalIndex.upsert(
      MediaLocalRecord(
        key: key,
        attachmentId: id,
        path: fields['local_device_path']?.toString(),
        assetId: fields['local_asset_id']?.toString(),
        kind: isVideoAttachment(attachment) ? 'video' : 'image',
        serverUrl: galleryAttachmentUrl(attachment),
        filename: GalleryMediaExport.filenameFor(attachment),
        skipPhoneAlbum: false,
      ),
    );
  }

  static void _applyLocalFields(
    Map<String, dynamic> attachment,
    Map<String, dynamic> fields,
  ) {
    attachment['local_device_path'] = fields['local_device_path'];
    final assetId = fields['local_asset_id']?.toString().trim() ?? '';
    if (assetId.isNotEmpty) {
      attachment['local_asset_id'] = assetId;
    }
    final kind = fields['local_media_kind']?.toString().trim() ?? '';
    if (kind.isNotEmpty) {
      attachment['local_media_kind'] = kind;
    }
    attachment['skip_phone_album'] = false;
  }

  /// После ручного «Скачать»: снять skip и записать путь из альбома FamilyChat.
  static Future<void> rememberAfterUserSave(
    Map<String, dynamic> attachment, {
    Future<Uint8List> Function()? fetchBytes,
  }) =>
      saveByUserDownload(attachment, fetchBytes: fetchBytes);

  /// Удаление из приложения → удалить копию из папки FamilyChat.
  static Future<void> deleteFromPhone(Map<String, dynamic> attachment) async {
    await MediaLocalIndex.ensureLoaded();
    MediaLocalIndex.hydrateAttachment(attachment);
    final rec = MediaLocalIndex.peekByAttachmentId(
          attachment['id'] is int
              ? attachment['id'] as int
              : int.tryParse('${attachment['id']}'),
        ) ??
        MediaLocalIndex.peekByFilename(attachment['filename']?.toString());
    if (rec?.isOutgoing == true) {
      // Свой оригинал в Camera/галерее не трогаем — только копии FamilyChat.
      return;
    }
    await GalleryDeviceMediaStore.deleteFromPhoneAlbum(
      assetId: rec?.assetId ?? attachment['local_asset_id']?.toString(),
      filename: GalleryMediaExport.filenameFor(attachment),
    );
    if (rec != null) {
      await MediaLocalIndex.remove(rec.key);
    }
  }
}
