import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

bool localDeviceFileExists(String? path) {
  final trimmed = path?.trim() ?? '';
  if (trimmed.isEmpty) return false;
  try {
    return File(trimmed).existsSync();
  } catch (_) {
    return false;
  }
}

Widget localDeviceFileImage({
  required String path,
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
  Widget? error,
}) {
  return Image.file(
    File(path),
    width: width,
    height: height,
    fit: fit,
    gaplessPlayback: true,
    errorBuilder: (_, __, ___) => error ?? const SizedBox.shrink(),
  );
}

VideoPlayerController? localDeviceVideoController(String path) {
  try {
    if (!File(path).existsSync()) return null;
    return VideoPlayerController.file(File(path));
  } catch (_) {
    return null;
  }
}
