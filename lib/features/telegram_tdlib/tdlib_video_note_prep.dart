import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native square crop for Telegram video notes (TDLib rejects non-square mp4).
class TdlibVideoNotePrep {
  TdlibVideoNotePrep._();

  static const _channel = MethodChannel('com.familychat/video_note_prep');

  /// Returns path + side length suitable for [inputMessageVideoNote.length].
  static Future<({String path, int length})> prepareSquare(
    String path, {
    int maxSide = 384,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      return (path: path, length: maxSide);
    }
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'prepareSquare',
        {
          'path': path,
          'maxSide': maxSide,
        },
      );
      if (res == null) return (path: path, length: maxSide);
      final out = res['path']?.toString();
      final len = (res['length'] as num?)?.toInt() ?? maxSide;
      if (out == null || out.isEmpty) return (path: path, length: maxSide);
      return (path: out, length: len.clamp(96, 640));
    } catch (e) {
      debugPrint('[tdlib] video-note prep failed: $e');
      return (path: path, length: maxSide);
    }
  }
}
