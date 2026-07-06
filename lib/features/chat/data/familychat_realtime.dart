import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/env.dart';

typedef FamilyChatRealtimeHandler = void Function(Map<String, dynamic> event);

class FamilyChatRealtime {
  FamilyChatRealtime._();
  static FamilyChatRealtime? _instance;
  static FamilyChatRealtime get instance => _instance ??= FamilyChatRealtime._();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _listeners = <FamilyChatRealtimeHandler>{};

  void addListener(FamilyChatRealtimeHandler handler) => _listeners.add(handler);

  void removeListener(FamilyChatRealtimeHandler handler) =>
      _listeners.remove(handler);

  void emitSyntheticEvent(Map<String, dynamic> event) {
    for (final h in _listeners) {
      h(event);
    }
  }

  Future<void> connect(String accessToken) async {
    if (accessToken.isEmpty) return;
    await disconnect();
    final uri = Env.familychatWsUri(accessToken);
    _channel = WebSocketChannel.connect(uri);
    _sub = _channel!.stream.listen(
      (data) {
        try {
          final map = jsonDecode(data as String) as Map<String, dynamic>;
          for (final h in _listeners) {
            h(map);
          }
        } catch (_) {}
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }
}
