import 'package:share_handler/share_handler.dart';

class ShareAttachmentData {
  const ShareAttachmentData({
    required this.bytes,
    required this.filename,
    this.contentType,
    this.isImage = false,
  });

  final List<int> bytes;
  final String filename;
  final String? contentType;
  final bool isImage;
}

Future<List<ShareAttachmentData>> loadShareAttachments(SharedMedia media) async =>
    const [];
