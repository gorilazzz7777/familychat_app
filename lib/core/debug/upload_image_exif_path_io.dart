import 'dart:io';
import 'dart:typed_data';

Future<Uint8List?> readBytesFromPath(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}
