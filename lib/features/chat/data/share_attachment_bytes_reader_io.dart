import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.familychat/share_intent');

/// Читает байты из оригинального content:// URI share-intent (Android Q+ с GPS).
/// Если не удалось — возвращает [fallbackBytes].
Future<Uint8List?> readShareAttachmentBytes({
  required int index,
  required Uint8List fallbackBytes,
}) async {
  if (!Platform.isAndroid) return fallbackBytes;
  try {
    final raw = await _channel.invokeMethod<dynamic>(
      'readPendingImageBytes',
      {'index': index},
    );
    if (raw is Uint8List && raw.isNotEmpty) return raw;
    if (raw is ByteData && raw.lengthInBytes > 0) {
      return raw.buffer.asUint8List();
    }
    if (raw is List && raw.isNotEmpty) {
      return Uint8List.fromList(raw.cast<int>());
    }
  } catch (_) {}
  return fallbackBytes;
}

Future<void> clearPendingShareAttachmentUris() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<void>('clearPendingShareUris');
  } catch (_) {}
}
