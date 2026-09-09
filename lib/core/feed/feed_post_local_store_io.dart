import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Долговечное хранилище байтов для outbox (не temp — OS не чистит).
abstract final class FeedPostLocalStore {
  static Future<Directory?> _dir() async {
    try {
      final root = await getApplicationSupportDirectory();
      final dir = Directory('${root.path}/feed_post_outbox');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^\w.\-]'), '_');

  static Future<String?> store({
    required String id,
    required Uint8List bytes,
    required String filename,
  }) async {
    final dir = await _dir();
    if (dir == null) return null;
    try {
      final file = File('${dir.path}/${_safe(id)}_${_safe(filename)}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> read(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
