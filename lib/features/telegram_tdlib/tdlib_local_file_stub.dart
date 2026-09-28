import 'package:flutter/widgets.dart';

/// Web: no local files from TDLib.
bool tdlibLocalFileExists(String? path) => false;

Widget tdlibLocalFileImage(
  String path, {
  BoxFit fit = BoxFit.cover,
  double? width,
  double? height,
}) {
  return SizedBox(width: width, height: height);
}
