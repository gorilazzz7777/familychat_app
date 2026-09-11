import '../../../../../core/media/gallery_media_utils.dart';

int? _asInt(dynamic raw) {
  if (raw is int) return raw;
  return int.tryParse('$raw');
}

/// FamilyChat ChatAttachment identity for a diary milestone photo.
///
/// Diary `attachment_id` / `thread_id` live in another table. The same numbers
/// often exist in FamilyChat sqlite (`a:{id}`, `attachments/{thread}_{id}`)
/// for a **different** file — preview uses S3 `url`, viewer then shows the
/// cached FamilyChat twin. Only `fc_attachment_id` is safe for the FC viewer.
({int attachmentId, int threadId})? milestoneFamilyChatIdentity(
  Map<String, dynamic> photo,
) {
  final attachmentId = _asInt(photo['fc_attachment_id']);
  final threadId = _asInt(photo['fc_thread_id']);
  if (attachmentId == null || attachmentId <= 0) return null;
  if (threadId == null || threadId <= 0) return null;
  return (attachmentId: attachmentId, threadId: threadId);
}

/// Payload without Diary ids, so [MediaLocalIndex] cannot overlay another file.
Map<String, dynamic> milestonePhotoForUrlViewer(Map<String, dynamic> photo) {
  return {
    ...photo,
  }
    ..remove('id')
    ..remove('attachment_id')
    ..remove('thread_id')
    ..remove('filename');
}

/// Фото вехи → формат [GalleryPhotoViewerScreen] (id = FamilyChat ChatAttachment.id).
///
/// Если хотя бы у одного кадра нет fc_* — пустой список: вызывающий код
/// открывает URL-просмотрщик, а не sqlite/content API с diary id.
List<Map<String, dynamic>> milestonePhotosForGalleryViewer(
  Iterable<Map<String, dynamic>> photos,
) {
  final out = <Map<String, dynamic>>[];
  for (final photo in photos) {
    if (!isGalleryMediaAttachment(photo) &&
        galleryAttachmentUrl(photo).isEmpty) {
      continue;
    }
    final identity = milestoneFamilyChatIdentity(photo);
    if (identity == null) return [];
    out.add({
      ...photo,
      'id': identity.attachmentId,
      'attachment_id': identity.attachmentId,
      'thread_id': identity.threadId,
      'file_url': photo['file_url'] ?? photo['url'],
      'url': photo['url'] ?? photo['file_url'],
      if (photo['kind'] == null && photo['media_type'] != null)
        'kind': photo['media_type'],
    });
  }
  return out;
}
