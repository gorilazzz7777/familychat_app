import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';

const _forceUploadExifLog = bool.fromEnvironment('LOG_UPLOAD_EXIF', defaultValue: false);

/// Логирует EXIF/GPS байтов перед загрузкой.
/// Debug-сборка или `--dart-define=LOG_UPLOAD_EXIF=true`.
Future<void> logUploadImageExifDiagnostics({
  required Uint8List bytes,
  required String filename,
  String? sourcePath,
  String? readVia,
}) async {
  if (!kDebugMode && !_forceUploadExifLog) return;

  final head = StringBuffer('upload_exif_diag')
    ..write(' filename=$filename')
    ..write(' bytes=${bytes.length}');
  if (sourcePath != null && sourcePath.isNotEmpty) {
    head.write(' path=$sourcePath');
  }
  if (readVia != null && readVia.isNotEmpty) {
    head.write(' read_via=$readVia');
  }

  try {
    final tags = await readExifFromBytes(bytes);
    if (tags.isEmpty) {
      debugPrint('$head exif=empty');
      return;
    }

    final takenAt = tags['EXIF DateTimeOriginal']?.printable ??
        tags['Image DateTime']?.printable;
    final lat = tags['GPS GPSLatitude']?.printable;
    final lon = tags['GPS GPSLongitude']?.printable;
    final latRef = tags['GPS GPSLatitudeRef']?.printable;
    final lonRef = tags['GPS GPSLongitudeRef']?.printable;
    final gpsKeys = tags.keys.where((k) => k.startsWith('GPS ')).toList()..sort();

    head
      ..write(' taken_at=${takenAt ?? 'none'}')
      ..write(' gps_lat=${lat ?? 'none'}')
      ..write(' gps_lon=${lon ?? 'none'}')
      ..write(' gps_lat_ref=${latRef ?? 'none'}')
      ..write(' gps_lon_ref=${lonRef ?? 'none'}')
      ..write(' gps_zeroed=${_looksLikeZeroedGps(lat, lon)}')
      ..write(' gps_tag_count=${gpsKeys.length}');

    debugPrint(head.toString());
    if (gpsKeys.isNotEmpty) {
      debugPrint('upload_exif_diag gps_tags: ${gpsKeys.join(', ')}');
    }
  } catch (e) {
    debugPrint('$head exif_error=$e');
  }
}

bool _looksLikeZeroedGps(String? lat, String? lon) {
  if (lat == null && lon == null) return false;
  final combined = '${lat ?? ''} ${lon ?? ''}';
  if (combined.trim().isEmpty) return true;
  final onlyZeros = RegExp(r'^[0/,\s]+$');
  return onlyZeros.hasMatch(combined.replaceAll('deg', '').trim());
}
