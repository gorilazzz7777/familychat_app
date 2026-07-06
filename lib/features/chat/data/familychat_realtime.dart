import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/env.dart';
import 'chat_realtime_utils.dart';

typedef FamilyChatRealtimeHandler = void Function(Map<String, dynamic> event);

class FamilyChatRealtime {
  FamilyChatRealtime._();
  static FamilyChatRealtime? _instance;
  static FamilyChatRealtime get instance => _instance ??= FamilyChatRealtime._();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _listeners = <FamilyChatRealtimeHandler>{};
  String? _accessToken;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _connecting = false;

  void addListener(FamilyChatRealtimeHandler handler) => _listeners.add(handler);

  void removeListener(FamilyChatRealtimeHandler handler) =>
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
      final uri = Env.familychatWsUri(accessToken);
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        (data) {
          _reconnectAttempt = 0;
          try {
            final decoded = jsonDecode(data as String);
            if (decoded is! Map) return;
            _dispatch(chatNormalizeMap(Map<dynamic, dynamic>.from(decoded)));
          } catch (e) {
            debugPrint('familychat ws decode error: $e');
          }
        },
        onError: (Object error) {
          debugPrint('familychat ws error: $error');
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('familychat ws closed');
          _scheduleReconnect();
        },
      );
    } catch (e) {
      debugPrint('familychat ws connect error: $e');
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
  }
}
