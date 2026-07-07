import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

const _channel = MethodChannel('com.familychat/share_intent');

class ShareAttachmentBytesResult {
  const ShareAttachmentBytesResult({
    required this.bytes,
    required this.readVia,
  });

  final Uint8List bytes;
  final String readVia;
}

/// Читает байты из оригинального content:// URI share-intent (Android Q+ с GPS).
Future<ShareAttachmentBytesResult> readShareAttachmentBytes({
  required int index,
  required Uint8List fallbackBytes,
  required String filename,
}) async {
  if (!Platform.isAndroid) {
    return ShareAttachmentBytesResult(bytes: fallbackBytes, readVia: 'fallback');
  }

  await _ensureMediaLocationAccess();

  Uint8List bytes = fallbackBytes;
  var readVia = 'share_handler_cache';

  try {
    final raw = await _channel.invokeMethod<dynamic>(
      'readPendingImageBytes',
      {'index': index},
    );
    final fromUri = _decodeBytes(raw);
    if (fromUri != null && fromUri.isNotEmpty) {
      bytes = fromUri;
      readVia = fromUri.length == fallbackBytes.length ? 'share_intent_uri_same_size' : 'share_intent_uri';
    } else if (kDebugMode) {
      debugPrint('share_bytes: channel returned empty for index=$index');
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('share_bytes: channel error $e');
    }
  }

  if (await _looksLikeZeroedGps(bytes) && filename.isNotEmpty) {
    final origin = await _tryOriginBytesFromGallery(filename);
    if (origin != null && origin.isNotEmpty && !await _looksLikeZeroedGps(origin)) {
      bytes = origin;
      readVia = 'photo_manager_originFile';
    }
  }

  return ShareAttachmentBytesResult(bytes: bytes, readVia: readVia);
}

Future<void> clearPendingShareAttachmentUris() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<void>('clearPendingShareUris');
  } catch (_) {}
}

Future<void> _ensureMediaLocationAccess() async {
  if (!Platform.isAndroid) return;
  final status = await Permission.accessMediaLocation.status;
  if (status.isGranted) return;
  await Permission.accessMediaLocation.request();
}

Uint8List? _decodeBytes(Object? raw) {
  if (raw is Uint8List && raw.isNotEmpty) return raw;
  if (raw is ByteData && raw.lengthInBytes > 0) {
    return raw.buffer.asUint8List();
  }
  if (raw is List && raw.isNotEmpty) {
    return Uint8List.fromList(raw.cast<int>());
  }
  return null;
}

Future<bool> _looksLikeZeroedGps(Uint8List bytes) async {
  try {
    final tags = await readExifFromBytes(bytes);
    final lat = tags['GPS GPSLatitude']?.printable;
    final lon = tags['GPS GPSLongitude']?.printable;
    if (lat == null && lon == null) return false;
    bool isZero(String? value) {
      if (value == null || value.trim().isEmpty) return true;
      return RegExp(r'^[0/,\[\]\sdeg]+$').hasMatch(value.trim());
    }
    return isZero(lat) && isZero(lon);
  } catch (_) {
    return false;
  }
}

Future<Uint8List?> _tryOriginBytesFromGallery(String filename) async {
  try {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) return null;
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    const page = 200;
    for (final album in albums) {
      final count = await album.assetCountAsync;
      for (var offset = 0; offset < count; offset += page) {
        final end = math.min(offset + page, count);
        final assets = await album.getAssetListRange(start: offset, end: end);
        for (final asset in assets) {
          final title = await asset.titleAsync;
          if (title != filename) continue;
          final file = await asset.originFile ?? await asset.file;
          if (file == null) continue;
          return file.readAsBytes();
        }
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('share_bytes: photo_manager fallback failed $e');
    }
  }
  return null;
}
