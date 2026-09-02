import 'dart:async';
import 'dart:typed_data';

import '../../../app/shell_refresh.dart';
import '../../../core/feed/feed_photo_batch_session.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/image_upload_pipeline.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/media/video_upload_pipeline.dart';
import '../../chat/data/chat_attach_local_cache.dart';
import '../../familychat/data/familychat_repository.dart';

class FeedPostPhoto {
  const FeedPostPhoto({
    required this.bytes,
    required this.filename,
    this.contentType,
    this.photoExif,
    this.kind = 'image',
    this.localPath,
    this.thumbnailBytes,
    this.cacheId,
    this.uploadReady = false,
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
  final Map<String, dynamic>? photoExif;
  final String kind;
  final String? localPath;
  final Uint8List? thumbnailBytes;
  final String? cacheId;

  /// Уже сжато для upload — повторный prepare можно упростить.
  final bool uploadReady;

  /// Только лёгкое превью для UI. Никогда не отдаём сырые байты видео.
  Uint8List get previewBytes {
    final thumb = thumbnailBytes;
    if (thumb != null && thumb.isNotEmpty) return thumb;
    if (kind == 'video') return Uint8List(0);
    // Защита: полный кадр только если он уже маленький (после normalize).
    if (bytes.length <= 120 * 1024) return bytes;
    return Uint8List(0);
  }
}

/// Фоновая публикация поста в ленту (сжатие + upload после закрытия compose).
abstract final class FeedPostUploader {
  static const maxPhotos = 30;
  static const maxCaptionLength = 500;
  static const _thumbMaxSide = 360;
  static const _thumbQuality = 55;

  static Future<void> publish({
    required FamilyChatRepository repo,
    required List<FeedPostPhoto> photos,
    String caption = '',
    bool shareToDiary = false,
    int? childId,
    void Function(int index, int total, int sent, int totalBytes)?
        onUploadProgress,
  }) async {
    if (photos.isEmpty) return;

    final trimmedCaption = caption.trim();
    if (trimmedCaption.length > maxCaptionLength) {
      throw ArgumentError('Описание не длиннее $maxCaptionLength символов');
    }

    final batchId = createFeedPhotoBatchId();
    for (var i = 0; i < photos.length; i++) {
      final prepared = await _prepare(photos[i]);
      if (prepared == null) continue;
      final Map<String, dynamic> uploaded;
      if (childId != null) {
        uploaded = await repo.childGalleryUpload(
          childId: childId,
          bytes: prepared.bytes,
          filename: prepared.filename,
          contentType: prepared.contentType,
          batchId: batchId,
          photoExif: prepared.photoExif,
          onSendProgress: onUploadProgress == null
              ? null
              : (sent, total) =>
                  onUploadProgress(i, photos.length, sent, total),
        );
      } else {
        uploaded = await repo.familyGalleryUpload(
          bytes: prepared.bytes,
          filename: prepared.filename,
          contentType: prepared.contentType,
          destination: 'family_feed',
          batchId: batchId,
          shareToDiary: shareToDiary,
          photoExif: prepared.photoExif,
          onSendProgress: onUploadProgress == null
              ? null
              : (sent, total) =>
                  onUploadProgress(i, photos.length, sent, total),
        );
      }
      final uploadedId = uploaded['id'] is int
          ? uploaded['id'] as int
          : int.tryParse('${uploaded['id']}');
      final localPath = photos[i].localPath?.trim() ?? '';
      if (uploadedId != null && localPath.isNotEmpty) {
        unawaited(
          MediaLocalIndex.saveOutgoing(
            attachmentId: uploadedId,
            localPath: localPath,
            filename: prepared.filename,
            kind: prepared.kind,
          ),
        );
      }
    }
    await repo.completeFeedPhotoBatch(
      batchId,
      caption: trimmedCaption.isEmpty ? null : trimmedCaption,
      shareToDiary: childId == null ? shareToDiary : false,
    );
    await ShellRefresh.instance.refreshMainTabs();
  }

  /// Сразу возвращает управление: сжатие и upload идут в фоне.
  static void publishInBackground({
    required FamilyChatRepository repo,
    required List<FeedPostPhoto> photos,
    String caption = '',
    bool shareToDiary = false,
    int? childId,
  }) {
    unawaited(() async {
      try {
        await publish(
          repo: repo,
          photos: photos,
          caption: caption,
          shareToDiary: shareToDiary,
          childId: childId,
        );
      } catch (_) {
        // Ошибки не блокируют UI; лента обновится при следующем refresh.
      }
    }());
  }

  /// Сжимает фото и гарантирует лёгкий thumbnail — снижает OOM при публикации.
  static Future<FeedPostPhoto> normalizePhoto(FeedPostPhoto photo) async {
    if (photo.kind == 'video') {
      var thumb = photo.thumbnailBytes;
      if ((thumb == null || thumb.isEmpty) &&
          photo.bytes.isNotEmpty &&
          photo.bytes.length < 2 * 1024 * 1024) {
        // Не пытаемся «сжать» видео как картинку; без thumb — пустое превью.
        thumb = null;
      }
      return FeedPostPhoto(
        bytes: photo.bytes,
        filename: photo.filename,
        contentType:
            photo.contentType ?? contentTypeForFilename(photo.filename),
        photoExif: photo.photoExif,
        kind: 'video',
        localPath: photo.localPath,
        thumbnailBytes: thumb,
        cacheId: photo.cacheId,
        uploadReady: false,
      );
    }

    if (photo.uploadReady &&
        photo.thumbnailBytes != null &&
        photo.thumbnailBytes!.isNotEmpty) {
      return photo;
    }

    final draft = await prepareImageUploadDraft(
      originalBytes: photo.bytes,
      filename: photo.filename,
      contentType: photo.contentType,
      previewBytes: photo.thumbnailBytes,
      localPath: photo.localPath,
    );
    if (!draft.canUpload) {
      return photo;
    }

    var thumb = draft.thumbnailBytes;
    if (thumb == null || thumb.isEmpty || thumb.length > 180 * 1024) {
      thumb = await compressImageBytes(
        draft.bytesForUpload,
        maxSide: _thumbMaxSide,
        quality: _thumbQuality,
        localPath: photo.localPath,
      );
    }

    return FeedPostPhoto(
      bytes: draft.bytesForUpload,
      filename: draft.filename,
      contentType: draft.contentType,
      photoExif: draft.geo?.toPhotoExif() ?? photo.photoExif,
      kind: 'image',
      localPath: photo.localPath,
      thumbnailBytes: thumb,
      cacheId: photo.cacheId,
      uploadReady: true,
    );
  }

  static Future<List<FeedPostPhoto>> normalizePhotos(
    List<FeedPostPhoto> photos,
  ) async {
    final out = <FeedPostPhoto>[];
    for (final photo in photos) {
      out.add(await normalizePhoto(photo));
    }
    return out;
  }

  static Future<FeedPostPhoto?> _prepare(FeedPostPhoto photo) async {
    if (photo.kind == 'video') {
      final draft = await prepareVideoUploadDraft(
        originalBytes: photo.bytes,
        filename: photo.filename,
        contentType:
            photo.contentType ?? contentTypeForFilename(photo.filename),
        localPath: photo.localPath,
      );
      if (!draft.canUpload) return null;
      return FeedPostPhoto(
        bytes: draft.bytesForUpload,
        filename: draft.filename,
        contentType: draft.contentType,
        photoExif: draft.geo?.toPhotoExif() ?? photo.photoExif,
        kind: 'video',
        cacheId: photo.cacheId,
        uploadReady: true,
        localPath: photo.localPath,
      );
    }
    if (photo.uploadReady) {
      return FeedPostPhoto(
        bytes: photo.bytes,
        filename: photo.filename,
        contentType: photo.contentType ?? 'image/jpeg',
        photoExif: photo.photoExif,
        kind: 'image',
        cacheId: photo.cacheId,
        uploadReady: true,
        localPath: photo.localPath,
      );
    }
    final draft = await prepareImageUploadDraft(
      originalBytes: photo.bytes,
      filename: photo.filename,
      contentType: photo.contentType,
      previewBytes: photo.thumbnailBytes,
      localPath: photo.localPath,
    );
    if (!draft.canUpload) return null;
    return FeedPostPhoto(
      bytes: draft.bytesForUpload,
      filename: draft.filename,
      contentType: draft.contentType,
      photoExif: draft.geo?.toPhotoExif() ?? photo.photoExif,
      kind: 'image',
      cacheId: photo.cacheId,
      uploadReady: true,
      localPath: photo.localPath,
    );
  }

  static Future<void> cacheLocally(FeedPostPhoto photo) async {
    final id = photo.cacheId;
    if (id == null || id.isEmpty) return;
    // Кладём уже сжатые байты, если есть — иначе оригинал.
    await ChatAttachLocalCache.storeBytes(
      id: id,
      bytes: photo.bytes,
      filename: photo.filename,
    );
  }

  /// Optimistic-событие для мгновенного показа у автора.
  /// В [local_bytes] только миниатюры — иначе Image.memory роняет процесс (OOM).
  static Map<String, dynamic> buildOptimisticEvent({
    required List<FeedPostPhoto> photos,
    required String caption,
    required Map<String, dynamic> actor,
    int? childId,
    String? childName,
    String? childAvatarUrl,
    String? childGender,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final tempId = -DateTime.now().microsecondsSinceEpoch;
    return {
      'id': tempId,
      'kind': 'photo_batch_uploaded',
      'created_at': now,
      'is_new': false,
      '_optimistic': true,
      'actor': actor,
      'payload': {
        'caption': caption.trim(),
        'photo_count': photos.length,
        if (childId != null) 'child_id': childId,
        if (childName != null && childName.isNotEmpty) 'child_name': childName,
        if (childAvatarUrl != null && childAvatarUrl.isNotEmpty)
          'child_avatar_url': childAvatarUrl,
        if (childGender != null && childGender.isNotEmpty)
          'child_gender': childGender,
        'attachments': [
          for (var i = 0; i < photos.length; i++)
            {
              'id': tempId - i - 1,
              'thread_id': 0,
              'kind': photos[i].kind,
              'filename': photos[i].filename,
              if (photos[i].localPath != null &&
                  photos[i].localPath!.trim().isNotEmpty)
                'local_device_path': photos[i].localPath,
              if (photos[i].thumbnailBytes != null &&
                  photos[i].thumbnailBytes!.isNotEmpty)
                'local_bytes': photos[i].thumbnailBytes,
              '_optimistic': true,
            },
        ],
      },
    };
  }
}
