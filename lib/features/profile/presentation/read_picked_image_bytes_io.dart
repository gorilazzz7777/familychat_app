import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import '../../../core/debug/upload_image_exif_log.dart';

/// Читает байты выбранного фото с диска по [XFile.path].
/// [XFile.readAsBytes] на Android может вернуть перекодированную копию без EXIF/GPS.
Future<Uint8List> readPickedImageBytes(XFile file) async {
  final path = file.path;
  if (path.isNotEmpty) {
    final ioFile = File(path);
    if (await ioFile.exists()) {
      final bytes = await ioFile.readAsBytes();
      await logUploadImageExifDiagnostics(
        bytes: bytes,
        filename: file.name,
        sourcePath: path,
        readVia: 'file_path',
      );
      return bytes;
    }
  }
  final bytes = await file.readAsBytes();
  await logUploadImageExifDiagnostics(
    bytes: bytes,
    filename: file.name,
    sourcePath: path.isEmpty ? null : path,
    readVia: 'xfile_readAsBytes',
  );
  return bytes;
}
