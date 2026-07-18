import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

Future<Uint8List> readPickedImageBytes(XFile file) async {
  final path = file.path;
  if (!kIsWeb && path.isNotEmpty) {
    final ioFile = File(path);
    if (await ioFile.exists()) {
      return ioFile.readAsBytes();
    }
  }
  return file.readAsBytes();
}

Future<Uint8List?> readAlbumUploadFileBytes(PlatformFile file) async {
  if (file.bytes != null && file.bytes!.isNotEmpty) return file.bytes;
  final path = file.path;
  if (path == null || path.isEmpty || kIsWeb) return null;
  return File(path).readAsBytes();
}
