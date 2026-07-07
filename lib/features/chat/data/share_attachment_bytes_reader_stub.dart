import 'dart:typed_data';

class ShareAttachmentBytesResult {
  const ShareAttachmentBytesResult({
    required this.bytes,
    required this.readVia,
  });

  final Uint8List bytes;
  final String readVia;
}

Future<ShareAttachmentBytesResult> readShareAttachmentBytes({
  required int index,
  required Uint8List fallbackBytes,
  required String filename,
}) async =>
    ShareAttachmentBytesResult(bytes: fallbackBytes, readVia: 'fallback');

Future<void> clearPendingShareAttachmentUris() async {}
