import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

String galleryAttachmentUrl(Map<String, dynamic> attachment) {
  return attachment['url']?.toString() ??
      attachment['file_url']?.toString() ??
      attachment['server_url']?.toString() ??
      attachment['thumbnail_url']?.toString() ??
      '';
}

/// Локальный путь на телефоне (оригинал отправителя или копия FamilyChat).
/// Для видео предпочитаем [video_local_path], чтобы не открывать jpg-превью как mp4.
String galleryLocalDevicePath(Map<String, dynamic> attachment) {
  final video = attachment['video_local_path']?.toString().trim() ?? '';
  if (video.isNotEmpty) return video;
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

/// Pixel size from attachment metadata / EXIF, if known.
Size? galleryAttachmentPixelSize(Map<String, dynamic> attachment) {
  double w = (attachment['width'] as num?)?.toDouble() ?? 0;
  double h = (attachment['height'] as num?)?.toDouble() ?? 0;
  if (w <= 0 || h <= 0) {
    final exif = attachment['exif'];
    if (exif is Map) {
      w = (exif['ImageWidth'] as num?)?.toDouble() ??
          (exif['PixelXDimension'] as num?)?.toDouble() ??
          (exif['width'] as num?)?.toDouble() ??
          0;
      h = (exif['ImageLength'] as num?)?.toDouble() ??
          (exif['PixelYDimension'] as num?)?.toDouble() ??
          (exif['height'] as num?)?.toDouble() ??
          0;
    }
  }
  if (w > 0 && h > 0) return Size(w, h);
  return null;
}

/// Fullscreen photo fit (legacy): portrait/square cover; landscape contain.
/// Prefer [galleryFullscreenHomeScale] + [BoxFit.contain] for pinch-out reveal.
BoxFit galleryFullscreenPhotoFit(Map<String, dynamic> attachment) {
  final size = galleryAttachmentPixelSize(attachment);
  if (size != null) {
    return size.height >= size.width ? BoxFit.cover : BoxFit.contain;
  }
  return BoxFit.cover;
}

/// Max fraction of the photo that may be cropped when opening at cover.
///
/// Cover visible fraction = [contain]/[cover] (area and the cropped axis).
/// Cropped = `1 - contain/cover`. Cover only when that is ≤ this threshold.
const double kGalleryFullscreenMaxCoverCrop = 0.05;

/// Initial InteractiveViewer scale when the child is [BoxFit.contain]-fitted.
///
/// Opens at cover only when that would crop ≤ [kGalleryFullscreenMaxCoverCrop]
/// of the photo; otherwise stays at contain (full frame, may letterbox).
/// Pinch in still zooms past home; pinch out can go below contain.
double galleryFullscreenHomeScale({
  required double viewportWidth,
  required double viewportHeight,
  required double imageWidth,
  required double imageHeight,
  double maxCoverCrop = kGalleryFullscreenMaxCoverCrop,
}) {
  if (viewportWidth <= 0 || viewportHeight <= 0) return 1.0;
  var iw = imageWidth;
  var ih = imageHeight;
  if (iw <= 0 || ih <= 0) {
    // Until real pixels arrive, assume a typical phone portrait still.
    iw = 3;
    ih = 4;
  }
  final contain = math.min(viewportWidth / iw, viewportHeight / ih);
  final cover = math.max(viewportWidth / iw, viewportHeight / ih);
  if (contain <= 0) return 1.0;
  final coverOverContain = cover / contain;
  // Visible fraction of the image under cover == contain/cover.
  final cropped = 1.0 - (contain / cover);
  if (cropped <= maxCoverCrop) {
    return coverOverContain.clamp(1.0, 8.0);
  }
  return 1.0;
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
