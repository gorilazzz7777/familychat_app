import 'dart:typed_data';

String galleryAttachmentUrl(Map<String, dynamic> attachment) {
  return attachment['url']?.toString() ??
      attachment['file_url']?.toString() ??
      attachment['thumbnail_url']?.toString() ??
      '';
}

/// Потолок для [Image.memory]: полный кадр/видео в UI валит процесс (OOM).
const int kSafeLocalPreviewMaxBytes = 400 * 1024;

/// Байты, безопасные для превью в UI (миниатюра или уже маленький файл).
Uint8List? safeUiPreviewBytes({
  Uint8List? thumbnailBytes,
  Uint8List? bytes,
  String kind = 'image',
}) {
  final thumb = thumbnailBytes;
  if (thumb != null &&
      thumb.isNotEmpty &&
      thumb.length <= kSafeLocalPreviewMaxBytes) {
    return thumb;
  }
  if (kind == 'video' || kind == 'file') return null;
  if (bytes != null &&
      bytes.isNotEmpty &&
      bytes.length <= 120 * 1024) {
    return bytes;
  }
  return null;
}

bool isSafeUiPreviewBytes(Object? value) {
  return value is Uint8List &&
      value.isNotEmpty &&
      value.length <= kSafeLocalPreviewMaxBytes;
}

bool isVideoAttachment(Map<String, dynamic> attachment) {
  final mediaType = attachment['media_type']?.toString();
  if (mediaType == 'video') return true;
  final kind = attachment['kind']?.toString();
  if (kind == 'video') return true;
  final ct = attachment['content_type']?.toString().toLowerCase() ?? '';
  if (ct.startsWith('video/')) return true;
  final name = attachment['filename']?.toString().toLowerCase() ?? '';
  return name.endsWith('.mp4') ||
      name.endsWith('.mov') ||
      name.endsWith('.webm') ||
      name.endsWith('.3gp') ||
      name.endsWith('.m4v');
}

bool isImageAttachment(Map<String, dynamic> attachment) {
  if (isVideoAttachment(attachment)) return false;
  final mediaType = attachment['media_type']?.toString();
  if (mediaType == 'image') return true;
  final kind = attachment['kind']?.toString();
  if (kind == 'image') return true;
  final ct = attachment['content_type']?.toString().toLowerCase() ?? '';
  if (ct.startsWith('image/')) return true;
  final name = attachment['filename']?.toString().toLowerCase() ?? '';
  return name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.png') ||
      name.endsWith('.webp') ||
      name.endsWith('.heic') ||
      name.endsWith('.gif');
}

bool isGalleryMediaAttachment(Map<String, dynamic> attachment) {
  return isImageAttachment(attachment) || isVideoAttachment(attachment);
}

String contentTypeForFilename(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.3gp')) return 'video/3gpp';
  if (lower.endsWith('.m4v')) return 'video/x-m4v';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  return 'image/jpeg';
}
