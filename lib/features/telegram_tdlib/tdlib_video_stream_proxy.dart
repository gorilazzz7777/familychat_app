import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'tdlib_video_stream_proxy_types.dart';

export 'tdlib_video_stream_proxy_types.dart';

/// Localhost HTTP proxy so [VideoPlayerController.networkUrl] can issue Range
/// requests while TDLib fills the underlying file — same model as official TG
/// (player asks for parts → `downloadFile(offset, limit)`).
class TdlibVideoStreamProxy {
  TdlibVideoStreamProxy({
    required this.ensureRange,
    this.reviveSession,
  });

  final TdlibEnsureVideoRange ensureRange;
  final TdlibReviveVideoStreamSession? reviveSession;

  HttpServer? _server;
  int? _port;
  final Map<int, TdlibVideoStreamSession> _sessions = {};
  final Map<int, Future<void>> _rangeLocks = {};

  bool get isRunning => _server != null && _port != null;

  int? get port => _port;

  String? urlFor(int fileId) {
    final port = _port;
    if (port == null || !_sessions.containsKey(fileId)) return null;
    return 'http://127.0.0.1:$port/v/$fileId';
  }

  Future<void> ensureStarted() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    debugPrint('[tdlib-stream] proxy listen 127.0.0.1:$_port');
    server.listen(_onRequest, onError: (Object e) {
      debugPrint('[tdlib-stream] server err=$e');
    });
  }

  Future<String> register(TdlibVideoStreamSession session) async {
    await ensureStarted();
    _sessions[session.fileId] = session;
    final url = urlFor(session.fileId);
    if (url == null) {
      throw StateError('stream proxy failed to bind');
    }
    return url;
  }

  void unregister(int fileId) {
    _sessions.remove(fileId);
    _rangeLocks.remove(fileId);
  }

  Future<void> dispose() async {
    _sessions.clear();
    _rangeLocks.clear();
    final s = _server;
    _server = null;
    _port = null;
    await s?.close(force: true);
  }

  Future<void> _withRangeLock(int fileId, Future<void> Function() fn) async {
    final prev = _rangeLocks[fileId] ?? Future<void>.value();
    final gate = Completer<void>();
    _rangeLocks[fileId] = gate.future;
    try {
      await prev;
      await fn();
    } finally {
      gate.complete();
    }
  }

  Future<TdlibVideoStreamSession?> _sessionFor(int fileId) async {
    final existing = _sessions[fileId];
    if (existing != null) return existing;
    final revive = reviveSession;
    if (revive == null) return null;
    final session = await revive(fileId);
    if (session == null) return null;
    _sessions[fileId] = session;
    debugPrint('[tdlib-stream] revived session file=$fileId');
    return session;
  }

  Future<void> _onRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      // ExoPlayer sometimes hits `/v/123/` — accept trailing slash.
      final match = RegExp(r'^/v/(\d+)/?$').firstMatch(path);
      if (match == null) {
        debugPrint('[tdlib-stream] 404 bad-path path=$path');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final fileId = int.parse(match.group(1)!);
      final session = await _sessionFor(fileId);
      if (session == null) {
        debugPrint('[tdlib-stream] 404 no-session file=$fileId path=$path');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final size = session.expectedSize;
      if (size <= 0) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }

      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.contentTypeHeader, session.mimeType);
      request.response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');

      if (request.method == 'HEAD') {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = size;
        await request.response.close();
        return;
      }

      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      var start = 0;
      var end = size - 1;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      var isPartial = false;
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final spec = rangeHeader.substring(6).trim();
        final parts = spec.split('-');
        if (parts.isNotEmpty) {
          final a = parts[0].trim();
          final b = parts.length > 1 ? parts[1].trim() : '';
          if (a.isNotEmpty) start = int.tryParse(a) ?? 0;
          if (b.isNotEmpty) {
            end = int.tryParse(b) ?? (size - 1);
          } else if (a.isNotEmpty) {
            end = math.min(start + _defaultChunk - 1, size - 1);
          }
          isPartial = true;
        }
      } else {
        end = math.min(_defaultChunk - 1, size - 1);
        isPartial = end < size - 1;
      }

      start = start.clamp(0, size - 1);
      end = end.clamp(start, size - 1);
      final length = end - start + 1;

      TdlibVideoRangeReady? ready;
      await _withRangeLock(fileId, () async {
        ready = await ensureRange(
          fileId: fileId,
          offset: start,
          length: length,
        );
      });

      final hit = ready;
      if (hit == null || hit.available < length) {
        debugPrint(
          '[tdlib-stream] 503 range-miss file=$fileId '
          'off=$start len=$length got=${hit?.available ?? 0}',
        );
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }

      final file = File(hit.path);
      if (!await file.exists()) {
        debugPrint('[tdlib-stream] 404 missing-file file=$fileId path=${hit.path}');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      if (isPartial) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$size',
        );
        request.response.contentLength = length;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = length;
      }

      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(start);
        var remaining = length;
        final buf = List<int>.filled(math.min(64 * 1024, length), 0);
        while (remaining > 0) {
          final n = await raf.readInto(buf, 0, math.min(buf.length, remaining));
          if (n <= 0) break;
          request.response.add(buf.sublist(0, n));
          remaining -= n;
        }
      } finally {
        await raf.close();
      }
      await request.response.close();
    } catch (e, st) {
      debugPrint('[tdlib-stream] request fail: $e\n$st');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// First progressive window (~1MB) — moov-at-start + first GOPs.
  static const _defaultChunk = 1024 * 1024;
}
