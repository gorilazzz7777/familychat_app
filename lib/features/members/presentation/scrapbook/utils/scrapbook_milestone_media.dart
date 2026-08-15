import '../../../../../core/media/gallery_media_utils.dart';

List<Map<String, dynamic>> scrapbookMilestoneMedia(
  Map<String, dynamic> milestone,
) {
  final photos = milestone['photos'];
  if (photos is List && photos.isNotEmpty) {
    return photos
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .where((item) => galleryAttachmentUrl(item).isNotEmpty)
        .toList();
  }

  final cover = milestone['cover_url']?.toString() ?? '';
  if (cover.isEmpty) return const [];

  return [
    {
      'url': cover,
      'media_type': milestone['cover_media_type'],
    },
  ];
}

bool scrapbookMilestoneHasMedia(Map<String, dynamic> milestone) {
  return scrapbookMilestoneMedia(milestone).isNotEmpty;
}

int scrapbookMilestonePhotoCount(Map<String, dynamic> milestone) {
  return scrapbookMilestoneMedia(milestone)
      .where((item) => !isVideoAttachment(item))
      .length;
}

int scrapbookMilestoneVideoCount(Map<String, dynamic> milestone) {
  return scrapbookMilestoneMedia(milestone)
      .where(isVideoAttachment)
      .length;
}
