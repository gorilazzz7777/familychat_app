import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<Uint8List?> readAlbumUploadFileBytes(PlatformFile file) async {
  final bytes = file.bytes;
  if (bytes != null && bytes.isNotEmpty) {
    return bytes;
  }

  final stream = file.readStream;
  if (stream != null) {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    final merged = builder.takeBytes();
    return merged.isEmpty ? null : merged;
  }

  return null;
}
