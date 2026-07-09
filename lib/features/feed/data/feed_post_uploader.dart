import 'dart:typed_data';

import '../../../app/shell_refresh.dart';
import '../../../core/feed/feed_photo_batch_session.dart';
import '../../familychat/data/familychat_repository.dart';

class FeedPostPhoto {
  const FeedPostPhoto({
    required this.bytes,
    required this.filename,
    this.contentType,
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
}

abstract final class FeedPostUploader {
  static const maxPhotos = 30;
  static const maxCaptionLength = 500;

  static Future<void> publish({
    required FamilyChatRepository repo,
    required List<FeedPostPhoto> photos,
    String caption = '',
  }) async {
    if (photos.isEmpty) return;

    final trimmedCaption = caption.trim();
    if (trimmedCaption.length > maxCaptionLength) {
      throw ArgumentError('Описание не длиннее $maxCaptionLength символов');
    }

    final batchId = createFeedPhotoBatchId();
    for (final photo in photos) {
      await repo.familyGalleryUpload(
        bytes: photo.bytes,
        filename: photo.filename,
        contentType: photo.contentType,
        destination: 'family_feed',
        batchId: batchId,
      );
    }
    await repo.completeFeedPhotoBatch(
      batchId,
      caption: trimmedCaption.isEmpty ? null : trimmedCaption,
    );
    await ShellRefresh.instance.refreshMainTabs();
  }
}
