class ShareAttachmentData {
  const ShareAttachmentData({
    required this.filename,
    this.bytes = const [],
    this.contentType,
    this.isImage = false,
    this.isVideo = false,
    this.isAudio = false,
    this.durationMs,
    this.localPath,
  });

  final List<int> bytes;
  final String filename;
  final String? contentType;
  final bool isImage;
  final bool isVideo;
  final bool isAudio;
  final int? durationMs;
  final String? localPath;

  ShareAttachmentData copyWith({
    List<int>? bytes,
    String? filename,
    String? contentType,
    bool? isImage,
    bool? isVideo,
    bool? isAudio,
    int? durationMs,
    String? localPath,
  }) {
    return ShareAttachmentData(
      bytes: bytes ?? this.bytes,
      filename: filename ?? this.filename,
      contentType: contentType ?? this.contentType,
      isImage: isImage ?? this.isImage,
      isVideo: isVideo ?? this.isVideo,
      isAudio: isAudio ?? this.isAudio,
      durationMs: durationMs ?? this.durationMs,
      localPath: localPath ?? this.localPath,
    );
  }
}