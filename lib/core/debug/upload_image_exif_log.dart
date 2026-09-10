import 'dart:developer' as developer;

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'upload_image_exif_path.dart';

/// Временно включено по умолчанию для отладки GEO на iPhone.
/// Выключить: `--dart-define=LOG_UPLOAD_EXIF=false`.
const _enableUploadExifLog =
    bool.fromEnvironment('LOG_UPLOAD_EXIF', defaultValue: true);

void _exifLog(String message) {
  if (!_enableUploadExifLog) return;
  developer.log(message, name: 'upload_exif_diag');
  // ignore: avoid_print — нужен в release на устройстве (Xcode / Console / flutter logs)
  print('[upload_exif_diag] $message');
}

String describeImageMagic(Uint8List bytes) {
  if (bytes.length < 12) return 'too_short_${bytes.length}';
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpeg';
  if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
  // ftyp....heic / heif / mif1
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    return 'heif_ftyp_$brand';
  }
  return 'unknown_head_${bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

String _tagValueDump(IfdTag? tag) {
  if (tag == null) return 'null';
  final values = tag.values.toList();
  final parts = <String>[];
  for (var i = 0; i < values.length && i < 6; i++) {
    final v = values[i];
    if (v is Ratio) {
      parts.add('Ratio(${v.numerator}/${v.denominator})');
    } else {
      parts.add('${v.runtimeType}:$v');
    }
  }
  if (values.length > 6) parts.add('+${values.length - 6}');
  return 'printable="${tag.printable}" values=[${parts.join(', ')}]';
}

double? _gpsCoordinateFromTag(IfdTag? tag, String ref, {required Set<String> positiveRefs}) {
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

/// Логирует EXIF/GPS байтов перед загрузкой (работает и в release).
Future<void> logUploadImageExifDiagnostics({
  required Uint8List bytes,
  required String filename,
  String? sourcePath,
  String? readVia,
  String? stage,
  Map<String, dynamic>? outgoingPhotoExif,
}) async {
  if (!_enableUploadExifLog) return;

  final head = StringBuffer()
    ..write('stage=${stage ?? 'bytes'}')
    ..write(' filename=$filename')
    ..write(' bytes=${bytes.length}')
    ..write(' magic=${describeImageMagic(bytes)}');
  if (sourcePath != null && sourcePath.isNotEmpty) {
    head.write(' path=$sourcePath');
  }
  if (readVia != null && readVia.isNotEmpty) {
    head.write(' read_via=$readVia');
  }
  if (outgoingPhotoExif != null) {
    head.write(' outgoing_photo_exif=$outgoingPhotoExif');
  }

  try {
    final tags = await readExifFromBytes(bytes);
    if (tags.isEmpty) {
      _exifLog('$head exif=empty');
      return;
    }

    final takenAt = tags['EXIF DateTimeOriginal']?.printable ??
        tags['Image DateTime']?.printable;
    final latTag = tags['GPS GPSLatitude'];
    final lonTag = tags['GPS GPSLongitude'];
    final latRef = tags['GPS GPSLatitudeRef']?.printable ?? '';
    final lonRef = tags['GPS GPSLongitudeRef']?.printable ?? '';
    final gpsKeys = tags.keys.where((k) => k.contains('GPS')).toList()..sort();
    final parsedLat = _gpsCoordinateFromTag(
      latTag,
      latRef.isEmpty ? 'N' : latRef,
      positiveRefs: const {'N', 'n'},
    );
    final parsedLon = _gpsCoordinateFromTag(
      lonTag,
      lonRef.isEmpty ? 'E' : lonRef,
      positiveRefs: const {'E', 'e'},
    );

    head
      ..write(' tag_count=${tags.length}')
      ..write(' taken_at=${takenAt ?? 'none'}')
      ..write(' gps_tag_count=${gpsKeys.length}')
      ..write(' parsed_lat=${parsedLat ?? 'null'}')
      ..write(' parsed_lon=${parsedLon ?? 'null'}');

    _exifLog(head.toString());
    _exifLog('gps_lat ${_tagValueDump(latTag)} ref="$latRef"');
    _exifLog('gps_lon ${_tagValueDump(lonTag)} ref="$lonRef"');
    if (gpsKeys.isNotEmpty) {
      _exifLog('gps_keys: ${gpsKeys.join(', ')}');
      for (final key in gpsKeys.take(20)) {
        _exifLog('tag[$key] ${_tagValueDump(tags[key])}');
      }
    } else {
      // Без GPS — покажем несколько ключей, чтобы понять формат EXIF.
      final sample = tags.keys.take(12).toList()..sort();
      _exifLog('exif_sample_keys: ${sample.join(', ')}');
    }
  } catch (e, st) {
    _exifLog('$head exif_error=$e');
    if (kDebugMode) {
      _exifLog('$st');
    }
  }
}

/// Сравнивает GPS в разных источниках байтов одного AssetEntity (важно для iOS).
Future<void> logAssetGeoSourceDiagnostics(AssetEntity asset) async {
  if (!_enableUploadExifLog) return;
  if (asset.type != AssetType.image) return;

  final title = await asset.titleAsync;
  LatLng? asyncLatLng;
  try {
    asyncLatLng = await asset.latlngAsync();
  } catch (e) {
    _exifLog('asset latlngAsync error=$e');
  }
  _exifLog(
    'asset id=${asset.id} title=$title '
    'sync_lat=${asset.latitude} sync_lon=${asset.longitude} '
    'async_lat=${asyncLatLng?.latitude} async_lon=${asyncLatLng?.longitude} '
    'create=${asset.createDateTime} '
    'platform=${defaultTargetPlatform.name}',
  );

  Future<void> dumpSource(String label, Future<Uint8List?> Function() load) async {
    try {
      final bytes = await load();
      if (bytes == null || bytes.isEmpty) {
        _exifLog('asset_source=$label empty');
        return;
      }
      await logUploadImageExifDiagnostics(
        bytes: bytes,
        filename: title.isNotEmpty ? title : 'asset_${asset.id}.jpg',
        readVia: label,
        stage: 'asset_compare',
      );
    } catch (e) {
      _exifLog('asset_source=$label error=$e');
    }
  }

  await dumpSource('asset.file', () async {
    final f = await asset.file;
    if (f == null) return null;
    return f.readAsBytes();
  });
  await dumpSource('asset.originBytes', () => asset.originBytes);
  await dumpSource('asset.originFile', () async {
    final f = await asset.originFile;
    if (f == null) return null;
    return f.readAsBytes();
  });
}

/// Лог результата извлечения geo + что уйдёт на бэкенд.
void logPreparedImageGeo({
  required String filename,
  required int originalBytes,
  required int preparedBytes,
  required String? localPath,
  required Map<String, dynamic>? photoExif,
  required bool usedGeoHint,
}) {
  if (!_enableUploadExifLog) return;
  _exifLog(
    'prepared filename=$filename original_bytes=$originalBytes '
    'prepared_bytes=$preparedBytes path=${localPath ?? 'none'} '
    'used_geo_hint=$usedGeoHint photo_exif=${photoExif ?? 'null'} '
    'will_send_photo_exif=${photoExif != null && photoExif.isNotEmpty}',
  );
}

Future<void> logFilePathExifIfExists({
  required String? path,
  required String filename,
  String stage = 'local_path',
}) async {
  if (!_enableUploadExifLog) return;
  if (path == null || path.isEmpty) return;
  try {
    final bytes = await readBytesFromPath(path);
    if (bytes == null || bytes.isEmpty) {
      _exifLog('stage=$stage path=$path missing_or_empty');
      return;
    }
    await logUploadImageExifDiagnostics(
      bytes: bytes,
      filename: filename,
      sourcePath: path,
      readVia: 'File(path)',
      stage: stage,
    );
  } catch (e) {
    _exifLog('stage=$stage path=$path error=$e');
  }
}
