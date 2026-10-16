/// Callback used by the loopback HTTP proxy to pull a byte range via TDLib.
typedef TdlibEnsureVideoRange = Future<TdlibVideoRangeReady?> Function({
  required int fileId,
  required int offset,
  required int length,
});

/// Revive a dropped session (soft-restart / race) before answering ExoPlayer.
typedef TdlibReviveVideoStreamSession = Future<TdlibVideoStreamSession?> Function(
  int fileId,
);

class TdlibVideoRangeReady {
  const TdlibVideoRangeReady({
    required this.path,
    required this.available,
  });

  final String path;
  /// Contiguous bytes readable from [offset] (may be &gt; requested length).
  final int available;
}

class TdlibVideoStreamSession {
  TdlibVideoStreamSession({
    required this.fileId,
    required this.expectedSize,
    required this.mimeType,
    this.chatId,
  });

  final int fileId;
  final int expectedSize;
  final String mimeType;
  final int? chatId;
}
