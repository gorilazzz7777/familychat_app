import 'dart:typed_data';

/// Web: outbox bytes живут только в памяти сессии (IndexedDB позже при необходимости).
abstract final class FeedPostLocalStore {
  static final Map<String, Uint8List> _mem = {};

  static Future<String?> store({
    required String id,
    required Uint8List bytes,
    required String filename,
  }) async {
    final key = 'web_$id';
    _mem[key] = bytes;
    return key;
  }

  static Future<Uint8List?> read(String? path) async {
    if (path == null || path.isEmpty) return null;
    return _mem[path];
  }

  static Future<void> delete(String? path) async {
    if (path == null || path.isEmpty) return;
    _mem.remove(path);
  }
}
