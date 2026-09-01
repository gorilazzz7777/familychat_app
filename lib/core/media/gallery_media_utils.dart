import 'dart:typed_data';

String galleryAttachmentUrl(Map<String, dynamic> attachment) {
  return attachment['url']?.toString() ??
      attachment['file_url']?.toString() ??
      attachment['server_url']?.toString() ??
      attachment['thumbnail_url']?.toString() ??
      '';
}

/// Локальный путь на телефоне (оригинал отправителя или копия FamilyChat).
String galleryLocalDevicePath(Map<String, dynamic> attachment) {
  return attachment['local_device_path']?.toString().trim() ?? '';
}

/// Потолок для [Image.memory]: полный кадр/видео в UI валит процесс (OOM).
const int kSafeLocalPreviewMaxBytes = 400 * 1024;

/// JPEG / PNG / GIF / WebP — то, что [Image.memory] реально декодирует.
bool looksLikeImageBytes(Uint8List bytes) {
  if (bytes.length < 12) return false;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true; // JPEG
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true; // PNG
  }
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    return true; // GIF
  }
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true; // RIFF WEBP
  }
  return false;
}

/// ISO BMFF (mp4/mov) — нельзя кормить в [Image.memory].
bool looksLikeVideoBytes(Uint8List bytes) {
  if (bytes.length < 12) return false;
  if (bytes[4] != 0x66 ||
      bytes[5] != 0x74 ||
      bytes[6] != 0x79 ||
      bytes[7] != 0x70) {
    return false;
  }
  final brand =
      String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase().trim();
  const imageBrands = {'heic', 'heix', 'hevc', 'hevx', 'heif', 'mif1', 'msf1'};
  return !imageBrands.contains(brand);
}

/// Байты, безопасные для превью в UI (миниатюра или уже маленький файл).
Uint8List? safeUiPreviewBytes({
  Uint8List? thumbnailBytes,
  Uint8List? bytes,
  String kind = 'image',
}) {
  final thumb = thumbnailBytes;
  if (thumb != null &&
      thumb.isNotEmpty &&
      thumb.length <= kSafeLocalPreviewMaxBytes &&
      looksLikeImageBytes(thumb)) {
    return thumb;
  }
  if (kind == 'video' || kind == 'file') return null;
  if (bytes != null &&
      bytes.isNotEmpty &&
      bytes.length <= 120 * 1024 &&
      looksLikeImageBytes(bytes)) {
    return bytes;
  }
  return null;
}

bool isSafeUiPreviewBytes(Object? value) {
  return value is Uint8List &&
      value.isNotEmpty &&
      value.length <= kSafeLocalPreviewMaxBytes &&
      looksLikeImageBytes(value);
}

bool _pathLooksLikeVideo(String raw) {
  final path = raw.toLowerCase().split('?').first.split('#').first;
  return path.endsWith('.mp4') ||
      path.endsWith('.mov') ||
      path.endsWith('.webm') ||
      path.endsWith('.3gp') ||
      path.endsWith('.m4v');
}

bool isVideoAttachment(Map<String, dynamic> attachment) {
  final mediaType = attachment['media_type']?.toString();
  if (mediaType == 'video') return true;
  final localKind = attachment['local_media_kind']?.toString();
  if (localKind == 'video') return true;
  final kind = attachment['kind']?.toString();
  if (kind == 'video') return true;
  final ct = attachment['content_type']?.toString().toLowerCase() ?? '';
  if (ct.startsWith('video/')) return true;
  final name = attachment['filename']?.toString() ?? '';
  if (_pathLooksLikeVideo(name)) return true;
  final url = galleryAttachmentUrl(attachment);
  if (_pathLooksLikeVideo(url)) return true;
  final local = galleryLocalDevicePath(attachment);
  return _pathLooksLikeVideo(local);
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
  if (name.endsWith('.jpg') ||
      name.endsWith('.jpeg') ||
      name.endsWith('.png') ||
      name.endsWith('.webp') ||
      name.endsWith('.heic') ||
      name.endsWith('.gif')) {
    return true;
  }
  final url = galleryAttachmentUrl(attachment).toLowerCase();
  return url.endsWith('.jpg') ||
      url.endsWith('.jpeg') ||
      url.endsWith('.png') ||
      url.endsWith('.webp') ||
      url.endsWith('.heic') ||
      url.endsWith('.gif');
}

bool isGalleryMediaAttachment(Map<String, dynamic> attachment) {
  return isImageAttachment(attachment) || isVideoAttachment(attachment);
}

/// GIF/стикеры Klipy — только в чате, не в галерее и не в альбом телефона.
bool messageHasKlipyMedia(Map<String, dynamic>? metadata) {
  if (metadata == null || metadata.isEmpty) return false;
  return metadata['gif'] != null || metadata['sticker'] != null;
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
  if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
  if (lower.endsWith('.opus')) return 'audio/opus';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.aac')) return 'audio/aac';
  return 'image/jpeg';
}
