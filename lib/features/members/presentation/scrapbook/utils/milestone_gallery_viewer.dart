import '../../../../../core/media/gallery_media_utils.dart';

/// Фото вехи → формат [GalleryPhotoViewerScreen] (id = ChatAttachment.id).
List<Map<String, dynamic>> milestonePhotosForGalleryViewer(
  Iterable<Map<String, dynamic>> photos,
) {
  final out = <Map<String, dynamic>>[];
  for (final photo in photos) {
    if (!isGalleryMediaAttachment(photo) &&
        galleryAttachmentUrl(photo).isEmpty) {
      continue;
    }
    final rawAttId = photo['attachment_id'] ?? photo['id'];
    final attachmentId =
        rawAttId is int ? rawAttId : int.tryParse('$rawAttId');
    final threadId = photo['thread_id'] is int
        ? photo['thread_id'] as int
        : int.tryParse('${photo['thread_id']}');
    if (attachmentId == null || threadId == null) continue;
    out.add({
      ...photo,
      'id': attachmentId,
      'attachment_id': attachmentId,
      'thread_id': threadId,
      'file_url': photo['file_url'] ?? photo['url'],
      'url': photo['url'] ?? photo['file_url'],
      if (photo['kind'] == null && photo['media_type'] != null)
        'kind': photo['media_type'],
    });
  }
  return out;
}
