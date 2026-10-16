import 'tdlib_video_stream_proxy_types.dart';

export 'tdlib_video_stream_proxy_types.dart';

/// Web stub — TDLib video streaming needs dart:io loopback HTTP.
class TdlibVideoStreamProxy {
  TdlibVideoStreamProxy({
    required this.ensureRange,
    this.reviveSession,
  });

  final TdlibEnsureVideoRange ensureRange;
  final TdlibReviveVideoStreamSession? reviveSession;

  bool get isRunning => false;

  int? get port => null;

  String? urlFor(int fileId) => null;

  Future<void> ensureStarted() async {}

  Future<String> register(TdlibVideoStreamSession session) async {
    throw UnsupportedError('TDLib video streaming is not available on web');
  }

  void unregister(int fileId) {}

  Future<void> dispose() async {}
}
