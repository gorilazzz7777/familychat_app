import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../debug/upload_image_exif_log.dart';
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
  String? localPath,
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
    if (out.isNotEmpty) {
      if (!(out.length >= bytes.length && bytes.length < 400 * 1024)) {
        return Uint8List.fromList(out);
      }
      return bytes;
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('compressImageBytes list failed: $e');
    }
  }

  // iOS HEIC / сбой list-API: пробуем через файл на диске.
  final path = localPath;
  if (path != null && path.isNotEmpty) {
    try {
      final out = await FlutterImageCompress.compressWithFile(
        path,
        minWidth: maxSide,
        minHeight: maxSide,
        quality: quality,
        format: CompressFormat.jpeg,
      );
      if (out != null && out.isNotEmpty) {
        return Uint8List.fromList(out);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('compressImageBytes file failed: $e');
      }
    }
  }
  return bytes;
}

/// GPS из EXIF оригинала (до сжатия). Сжатый JPEG GPS обычно теряет.
Future<MediaGeo?> extractMediaGeoFromImageBytes(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  try {
    final tags = await readExifFromBytes(bytes);
    if (tags.isEmpty) return null;
    final lat = _gpsCoordinate(
      tags['GPS GPSLatitude'],
      tags['GPS GPSLatitudeRef']?.printable ?? 'N',
      positiveRefs: const {'N', 'n'},
    );
    final lon = _gpsCoordinate(
      tags['GPS GPSLongitude'],
      tags['GPS GPSLongitudeRef']?.printable ?? 'E',
      positiveRefs: const {'E', 'e'},
    );
    if (lat == null || lon == null) return null;
    if (lat.abs() < 1e-8 && lon.abs() < 1e-8) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return MediaGeo(latitude: lat, longitude: lon);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('extractMediaGeoFromImageBytes failed: $e');
    }
    return null;
  }
}

double? _gpsCoordinate(
  IfdTag? tag,
  String ref, {
  required Set<String> positiveRefs,
}) {
  if (tag == null) return null;
  final parts = tag.values.toList();
  if (parts.length < 3) return null;
  double? asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is Ratio) {
      if (v.denominator == 0) return null;
      return v.numerator / v.denominator;
    }
    return double.tryParse('$v');
  }

  final deg = asDouble(parts[0]);
  final min = asDouble(parts[1]);
  final sec = asDouble(parts[2]);
  if (deg == null || min == null || sec == null) return null;
  var value = deg + (min / 60.0) + (sec / 3600.0);
  final refTrim = ref.trim();
  if (refTrim.isNotEmpty && !positiveRefs.contains(refTrim[0])) {
    value = -value;
  }
  return value;
}

/// Подготовка фото: сжатие + draft для optimistic UI.
Future<MediaUploadDraft> prepareImageUploadDraft({
  required Uint8List originalBytes,
  required String filename,
  String? contentType,
  Uint8List? previewBytes,
  String? localPath,
  MediaGeo? geoHint,
}) async {
  final id = 'i_${DateTime.now().microsecondsSinceEpoch}';
  await logUploadImageExifDiagnostics(
    bytes: originalBytes,
    filename: filename,
    sourcePath: localPath,
    readVia: 'prepareImageUploadDraft.original',
    stage: 'before_geo_extract',
  );
  await logFilePathExifIfExists(
    path: localPath,
    filename: filename,
    stage: 'before_geo_extract_path',
  );
  // Гео берём из оригинала до сжатия — иначе GPS в EXIF пропадает.
  final geo = geoHint ?? await extractMediaGeoFromImageBytes(originalBytes);
  final thumb = previewBytes ??
      (originalBytes.length > 80 * 1024
          ? await compressImageBytes(
              originalBytes,
              maxSide: 480,
              quality: 60,
              localPath: localPath,
            )
          : originalBytes);
  final prepared = await compressImageBytes(
    originalBytes,
    localPath: localPath,
  );
  final outName = _jpegFilename(filename);
  final photoExif = geo?.toPhotoExif();
  logPreparedImageGeo(
    filename: outName,
    originalBytes: originalBytes.length,
    preparedBytes: prepared.length,
    localPath: localPath,
    photoExif: photoExif,
    usedGeoHint: geoHint != null,
  );
  await logUploadImageExifDiagnostics(
    bytes: prepared,
    filename: outName,
    sourcePath: localPath,
    readVia: 'prepareImageUploadDraft.prepared',
    stage: 'after_compress',
    outgoingPhotoExif: photoExif,
  );
  return MediaUploadDraft(
    id: id,
    kind: MediaDraftKind.image,
    filename: outName,
    contentType: 'image/jpeg',
    originalBytes: originalBytes,
    localPath: localPath,
    thumbnailBytes: thumb,
    preparedBytes: prepared,
    geo: geo,
  );
}

String _jpegFilename(String filename) {
  final base = filename.contains('.')
      ? filename.substring(0, filename.lastIndexOf('.'))
      : filename;
  final safe = base.trim().isEmpty ? 'photo' : base.trim();
  return '$safe.jpg';
}
