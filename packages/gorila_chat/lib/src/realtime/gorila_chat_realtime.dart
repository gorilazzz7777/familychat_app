import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../util/chat_realtime_utils.dart';

typedef GorilaChatRealtimeHandler = void Function(Map<String, dynamic> event);

/// Shared chat WebSocket client (Family Chat reference behaviour):
/// reconnect with backoff, normalize payloads, synthetic `chat_refresh`.
class GorilaChatRealtime {
  GorilaChatRealtime({
    required this.debugName,
    required this.uriForToken,
  });

  final String debugName;
  final Uri Function(String accessToken) uriForToken;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _listeners = <GorilaChatRealtimeHandler>{};
  String? _accessToken;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _connecting = false;
  bool _connected = false;

  bool get isConnected => _connected && _channel != null;

  void addListener(GorilaChatRealtimeHandler handler) => _listeners.add(handler);

  void removeListener(GorilaChatRealtimeHandler handler) =>
      _listeners.remove(handler);

  void emitSyntheticEvent(Map<String, dynamic> event) {
    _dispatch(chatNormalizeMap(Map<dynamic, dynamic>.from(event)));
  }

  Future<void> connect(String accessToken) async {
    if (accessToken.isEmpty) return;
    _accessToken = accessToken;
    _reconnectTimer?.cancel();
    if (_connecting) return;
    _connecting = true;
    try {
      await _closeChannel();
      final uri = uriForToken(accessToken);
      if (kDebugMode) {
        debugPrint('$debugName ws connect: $uri');
      }
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        (data) {
          _reconnectAttempt = 0;
          try {
            final decoded = jsonDecode(data as String);
            if (decoded is! Map) return;
            _dispatch(chatNormalizeMap(Map<dynamic, dynamic>.from(decoded)));
          } catch (e) {
            debugPrint('$debugName ws decode error: $e');
          }
        },
        onError: (Object error) {
          debugPrint('$debugName ws error: $error');
          _connected = false;
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('$debugName ws closed');
          _connected = false;
          _scheduleReconnect();
        },
        cancelOnError: false,
      );
      try {
        await _channel!.ready.timeout(const Duration(seconds: 20));
        _connected = true;
        _reconnectAttempt = 0;
      } catch (e) {
        debugPrint('$debugName ws connect error: $e');
        _connected = false;
        await _closeChannel();
        _scheduleReconnect();
      }
    } catch (e) {
      debugPrint('$debugName ws connect error: $e');
      _connected = false;
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _dispatch(Map<String, dynamic> event) {
    for (final handler in _listeners) {
      handler(event);
    }
  }

  void _scheduleReconnect() {
    final token = _accessToken;
    if (token == null || token.isEmpty) return;
    _reconnectTimer?.cancel();
    final seconds = math.min(30, math.pow(2, _reconnectAttempt).toInt());
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(connect(token));
    });
  }

  Future<void> disconnect() async {
    _accessToken = null;
    _reconnectAttempt = 0;
    _connected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeChannel();
  }

  Future<void> _closeChannel() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _connected = false;
  }

  /// Reconnect + tell open screens to HTTP-resync.
  Future<void> reconnectAndRefresh() async {
    final token = _accessToken;
    if (token != null && token.isNotEmpty) {
      await connect(token);
    }
    emitSyntheticEvent({'event': 'chat_refresh'});
  }

  void sendJson(Map<String, dynamic> payload) {
    final channel = _channel;
    if (!_connected || channel == null) return;
    try {
      channel.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('$debugName ws send error: $e');
    }
  }

  void sendTyping({required int threadId, required bool isTyping}) {
    sendJson({
      'event': 'chat_typing',
      'thread_id': threadId,
      'is_typing': isTyping,
    });
  }
}
