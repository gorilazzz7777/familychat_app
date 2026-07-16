import 'dart:typed_data';

class ChatAttachLocalCache {
  ChatAttachLocalCache._();

  static Future<String?> storeBytes({
    required String id,
    required Uint8List bytes,
    required String filename,
  }) async =>
      null;

  static Future<Uint8List?> readBytes(String? path) async => null;

  static Future<void> delete(String? path) async {}
}
