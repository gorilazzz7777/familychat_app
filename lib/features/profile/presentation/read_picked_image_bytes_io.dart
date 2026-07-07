import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

/// Читает байты выбранного фото с диска по [XFile.path].
/// [XFile.readAsBytes] на Android может вернуть перекодированную копию без EXIF/GPS.
Future<Uint8List> readPickedImageBytes(XFile file) async {
  final path = file.path;
  if (path.isNotEmpty) {
    final ioFile = File(path);
    if (await ioFile.exists()) {
      return ioFile.readAsBytes();
    }
  }
  return file.readAsBytes();
}
