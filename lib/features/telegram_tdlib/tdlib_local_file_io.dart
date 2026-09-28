import 'dart:io';

import 'package:flutter/widgets.dart';

bool tdlibLocalFileExists(String? path) {
  if (path == null || path.isEmpty) return false;
  return File(path).existsSync();
}

Widget tdlibLocalFileImage(
  String path, {
  BoxFit fit = BoxFit.cover,
  double? width,
  double? height,
}) {
  return Image.file(
    File(path),
    fit: fit,
    width: width,
    height: height,
  );
}
