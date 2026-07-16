import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class ChatAttachLocalCache {
  ChatAttachLocalCache._();

  static Future<Directory?> _dir() async {
    try {
      final root = await getTemporaryDirectory();
      final dir = Directory('${root.path}/chat_attach_cache');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> storeBytes({
    required String id,
    required Uint8List bytes,
    required String filename,
  }) async {
    final dir = await _dir();
    if (dir == null) return null;
    final safe = filename.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final file = File('${dir.path}/${id}_$safe');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  static Future<Uint8List?> readBytes(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
