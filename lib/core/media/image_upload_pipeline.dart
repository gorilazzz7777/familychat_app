import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'video_upload_pipeline.dart';

/// Максимальная длинная сторона после сжатия.
const int kImageMaxSide = 1920;

/// Качество JPEG (0–100).
const int kImageCompressQuality = 80;

/// Сжимает изображение перед загрузкой. Всегда вызывается для фото из чата.
Future<Uint8List> compressImageBytes(
  Uint8List bytes, {
  int maxSide = kImageMaxSide,
  int quality = kImageCompressQuality,
}) async {
  if (bytes.isEmpty) return bytes;
  try {
    final out = await FlutterImageCompress.compressWithList(
      bytes,
      minWidth: maxSide,
      minHeight: maxSide,
      quality: quality,
      format: CompressFormat.jpeg,
    );
    if (out.isEmpty) return bytes;
    // Не раздуваем файл, если сжатие вышло больше оригинала.
    if (out.length >= bytes.length && bytes.length < 400 * 1024) {
      return bytes;
    }
    return Uint8List.fromList(out);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('compressImageBytes failed: $e');
    }
    return bytes;
  }
}

/// Подготовка фото: сжатие + draft для optimistic UI.
Future<MediaUploadDraft> prepareImageUploadDraft({
  required Uint8List originalBytes,
  required String filename,
  String? contentType,
  Uint8List? previewBytes,
  String? localPath,
}) async {
  final id = 'i_${DateTime.now().microsecondsSinceEpoch}';
  final thumb = previewBytes ??
      (originalBytes.length > 80 * 1024
          ? await compressImageBytes(
              originalBytes,
              maxSide: 480,
              quality: 60,
            )
          : originalBytes);
  final prepared = await compressImageBytes(originalBytes);
  final outName = _jpegFilename(filename);
  return MediaUploadDraft(
    id: id,
    kind: MediaDraftKind.image,
    filename: outName,
    contentType: 'image/jpeg',
    originalBytes: originalBytes,
    localPath: localPath,
    thumbnailBytes: thumb,
    preparedBytes: prepared,
  );
}

String _jpegFilename(String filename) {
  final base = filename.contains('.')
      ? filename.substring(0, filename.lastIndexOf('.'))
      : filename;
  final safe = base.trim().isEmpty ? 'photo' : base.trim();
  return '$safe.jpg';
}
