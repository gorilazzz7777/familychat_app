import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

bool localDeviceFileExists(String? path) => false;

Widget localDeviceFileImage({
  required String path,
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
  Widget? error,
  int? cacheWidth,
  int? cacheHeight,
}) {
  return error ?? const SizedBox.shrink();
}

VideoPlayerController? localDeviceVideoController(String path) => null;
