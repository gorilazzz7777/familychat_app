import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../../core/debug/upload_image_exif_log.dart';

Future<Uint8List?> readAlbumUploadFileBytes(PlatformFile file) async {
  if (file.bytes != null && file.bytes!.isNotEmpty) {
    await logUploadImageExifDiagnostics(
      bytes: file.bytes!,
      filename: file.name,
      sourcePath: file.path,
      readVia: 'file_picker_bytes',
    );
    return file.bytes;
  }
  final path = file.path;
  if (path == null || path.isEmpty) return null;
  final bytes = await File(path).readAsBytes();
  await logUploadImageExifDiagnostics(
    bytes: bytes,
    filename: file.name,
    sourcePath: path,
    readVia: 'file_picker_path',
  );
  return bytes;
}
