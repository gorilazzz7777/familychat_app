class ShareAttachmentData {
  const ShareAttachmentData({
    required this.filename,
    this.bytes = const [],
    this.contentType,
    this.isImage = false,
    this.isVideo = false,
    this.localPath,
  });

  final List<int> bytes;
  final String filename;
  final String? contentType;
  final bool isImage;
  final bool isVideo;
  final String? localPath;
}
