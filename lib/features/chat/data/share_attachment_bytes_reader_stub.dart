import 'dart:typed_data';

Future<Uint8List?> readShareAttachmentBytes({
  required int index,
  required Uint8List fallbackBytes,
}) async =>
    fallbackBytes;

Future<void> clearPendingShareAttachmentUris() async {}
