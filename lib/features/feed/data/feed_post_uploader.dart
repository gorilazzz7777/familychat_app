import 'dart:async';
import 'dart:typed_data';

import '../../../app/shell_refresh.dart';
import '../../../core/feed/feed_photo_batch_session.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/image_upload_pipeline.dart';
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
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
  final Map<String, dynamic>? photoExif;
  final String kind;
  final String? localPath;
  final Uint8List? thumbnailBytes;
  final String? cacheId;

  Uint8List get previewBytes => thumbnailBytes ?? bytes;
}

/// Фоновая публикация поста в ленту (сжатие + upload после закрытия compose).
abstract final class FeedPostUploader {
  static const maxPhotos = 30;
  static const maxCaptionLength = 500;

  static Future<void> publish({
    required FamilyChatRepository repo,
    required List<FeedPostPhoto> photos,
    String caption = '',
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
      await repo.familyGalleryUpload(
        bytes: prepared.bytes,
        filename: prepared.filename,
        contentType: prepared.contentType,
        destination: 'family_feed',
        batchId: batchId,
        photoExif: prepared.photoExif,
        onSendProgress: onUploadProgress == null
            ? null
            : (sent, total) => onUploadProgress(i, photos.length, sent, total),
      );
    }
    await repo.completeFeedPhotoBatch(
      batchId,
      caption: trimmedCaption.isEmpty ? null : trimmedCaption,
    );
    await ShellRefresh.instance.refreshMainTabs();
  }

  /// Сразу возвращает управление: сжатие и upload идут в фоне.
  static void publishInBackground({
    required FamilyChatRepository repo,
    required List<FeedPostPhoto> photos,
    String caption = '',
  }) {
    unawaited(() async {
      try {
        await publish(repo: repo, photos: photos, caption: caption);
      } catch (_) {
        // Ошибки не блокируют UI; лента обновится при следующем refresh.
      }
    }());
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
    );
  }

  static Future<void> cacheLocally(FeedPostPhoto photo) async {
    final id = photo.cacheId;
    if (id == null || id.isEmpty) return;
    await ChatAttachLocalCache.storeBytes(
      id: id,
      bytes: photo.bytes,
      filename: photo.filename,
    );
  }

  /// Optimistic-событие для мгновенного показа у автора.
  static Map<String, dynamic> buildOptimisticEvent({
    required List<FeedPostPhoto> photos,
    required String caption,
    required Map<String, dynamic> actor,
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
        'attachments': [
          for (var i = 0; i < photos.length; i++)
            {
              'id': tempId - i - 1,
              'thread_id': 0,
              'kind': photos[i].kind,
              'filename': photos[i].filename,
              'local_bytes': photos[i].previewBytes,
              '_optimistic': true,
            },
        ],
      },
    };
  }
}
