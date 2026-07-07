import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<Uint8List?> readAlbumUploadFileBytes(PlatformFile file) async {
  final bytes = file.bytes;
  if (bytes == null || bytes.isEmpty) return null;
  return bytes;
}
