import 'dart:async';
import 'dart:typed_data';

import '../../../core/feed/feed_photo_batch_session.dart';
import '../../../core/feed/feed_post_outbox.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/image_upload_pipeline.dart';
import '../../../core/media/video_upload_pipeline.dart';
import '../../chat/data/chat_attach_local_cache.dart';
import '../../familychat/data/familychat_repository.dart';
import '../../../core/media/media_upload_limits.dart';
import '../../../core/media/media_upload_foreground.dart';

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
    this.assetId,
    this.assetFingerprint,
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
  final String? assetId;
  final String? assetFingerprint;

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
  static const maxPhotos = kMaxMediaUploadCount;
  static const maxCaptionLength = 500;
  static const _thumbMaxSide = 360;
  static const _thumbQuality = 55;

  static Future<void> publish({
    required FamilyChatRepository repo,
    required List<FeedPostPhoto> photos,
    String caption = '',
    bool shareToDiary = false,
    int? childId,
    int? optimisticId,
    void Function(int index, int total, int sent, int totalBytes)?
        onUploadProgress,
  }) async {
    if (photos.isEmpty) return;

    final trimmedCaption = caption.trim();
    if (trimmedCaption.length > maxCaptionLength) {
      throw ArgumentError('Описание не длиннее $maxCaptionLength символов');
    }

    final batchId = createFeedPhotoBatchId();
    await FeedPostOutbox.instance.enqueue(
      batchId: batchId,
      photos: photos,
      caption: trimmedCaption,
      shareToDiary: shareToDiary,
      childId: childId,
      optimisticId: optimisticId,
    );
    await FeedPostOutbox.instance.flush(repo);
  }

  /// Сразу возвращает управление: сжатие и upload идут в фоне через outbox.
  static void publishInBackground({
    required FamilyChatRepository repo,
    required List<FeedPostPhoto> photos,
    String caption = '',
    bool shareToDiary = false,
    int? childId,
    int? optimisticId,
    String? batchId,
  }) {
    if (photos.isEmpty) return;
    unawaited(MediaUploadForeground.enter(MediaUploadForeground.scopeFeed));
    unawaited(() async {
      try {
        final trimmedCaption = caption.trim();
        if (trimmedCaption.length > maxCaptionLength) {
          throw ArgumentError('Описание не длиннее $maxCaptionLength символов');
        }
        final id = (batchId != null && batchId.isNotEmpty)
            ? batchId
            : createFeedPhotoBatchId();
        await FeedPostOutbox.instance.enqueue(
          batchId: id,
          photos: photos,
          caption: trimmedCaption,
          shareToDiary: shareToDiary,
          childId: childId,
          optimisticId: optimisticId,
        );
        await FeedPostOutbox.instance.flush(repo);
      } catch (_) {
        // Outbox сохранит pending — flush на следующем старте/resume.
      } finally {
        await MediaUploadForeground.leave(MediaUploadForeground.scopeFeed);
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
        assetId: photo.assetId,
        assetFingerprint: photo.assetFingerprint,
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
      assetId: photo.assetId,
      assetFingerprint: photo.assetFingerprint,
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
        assetId: photo.assetId,
        assetFingerprint: photo.assetFingerprint,
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
        assetId: photo.assetId,
        assetFingerprint: photo.assetFingerprint,
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
      assetId: photo.assetId,
      assetFingerprint: photo.assetFingerprint,
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
    String? batchId,
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
        if (batchId != null && batchId.isNotEmpty) 'batch_id': batchId,
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
