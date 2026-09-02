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
  /// True when the next successful [connect] should emit `chat_refresh`
  /// (after drop / backoff reconnect — open chats must HTTP-resync).
  bool _refreshAfterConnect = false;
  final Map<int, _PendingWsTextSend> _pendingTextSends = {};
  final Map<int, Completer<bool>> _pendingMarkReads = {};

  static const _defaultSendAckTimeout = Duration(seconds: 2);
  static const _defaultMarkReadAckTimeout = Duration(seconds: 3);

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
            final event = chatNormalizeMap(Map<dynamic, dynamic>.from(decoded));
            if (_handleSendControlEvent(event)) return;
            if (_handleMarkReadAckEvent(event)) return;
            _dispatch(event);
          } catch (e) {
            debugPrint('$debugName ws decode error: $e');
          }
        },
        onError: (Object error) {
          debugPrint('$debugName ws error: $error');
          _connected = false;
          _failPendingTextSends();
          _failPendingMarkReads();
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('$debugName ws closed');
          _connected = false;
          _failPendingTextSends();
          _failPendingMarkReads();
          _scheduleReconnect();
        },
        cancelOnError: false,
      );
      try {
        await _channel!.ready.timeout(const Duration(seconds: 20));
        _connected = true;
        _reconnectAttempt = 0;
        emitSyntheticEvent({'event': 'ws_connected'});
        if (_refreshAfterConnect) {
          _refreshAfterConnect = false;
          emitSyntheticEvent({'event': 'chat_refresh', 'force': true});
        }
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
    _refreshAfterConnect = true;
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
    _failPendingTextSends();
    _failPendingMarkReads();
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
    emitSyntheticEvent({'event': 'chat_refresh', 'force': true});
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

  void sendPresenceUpdate({required bool appInForeground}) {
    sendJson({
      'event': 'presence_update',
      'app_foreground': appInForeground,
    });
  }

  /// Mark thread read via WS. Returns false on timeout/disconnect.
  Future<bool> sendMarkRead({
    required int threadId,
    required int lastMessageId,
    Duration timeout = _defaultMarkReadAckTimeout,
  }) async {
    if (!isConnected || threadId <= 0 || lastMessageId <= 0) return false;

    final previous = _pendingMarkReads.remove(threadId);
    if (previous != null && !previous.isCompleted) {
      previous.complete(false);
    }

    final completer = Completer<bool>();
    _pendingMarkReads[threadId] = completer;

    sendJson({
      'event': 'chat_mark_read',
      'thread_id': threadId,
      'last_message_id': lastMessageId,
    });

    try {
      return await completer.future.timeout(timeout);
    } catch (_) {
      final pending = _pendingMarkReads.remove(threadId);
      if (pending != null && !pending.isCompleted) {
        pending.complete(false);
      }
      return false;
    }
  }

  /// Text-only send via WS. Returns server message dict or null on timeout/disconnect.
  Future<Map<String, dynamic>?> sendTextMessage({
    required int threadId,
    required int clientMsgId,
    String? body,
    int? replyToMessageId,
    List<int>? mentionedUserIds,
    bool notifySilent = false,
    Duration timeout = _defaultSendAckTimeout,
  }) async {
    if (!isConnected) return null;
    final trimmed = body?.trim() ?? '';
    if (trimmed.isEmpty) return null;

    final completer = Completer<Map<String, dynamic>>();
    _pendingTextSends[clientMsgId] = _PendingWsTextSend(completer: completer);

    sendJson({
      'event': 'chat_send_message',
      'thread_id': threadId,
      'client_msg_id': clientMsgId,
      'body': trimmed,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (mentionedUserIds != null && mentionedUserIds.isNotEmpty)
        'mentioned_user_ids': mentionedUserIds,
      if (notifySilent) 'notify_silent': true,
    });

    try {
      return await completer.future.timeout(timeout);
    } catch (_) {
      _pendingTextSends.remove(clientMsgId);
      return null;
    }
  }

  bool _handleSendControlEvent(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev == 'chat_send_ack') {
      final clientMsgId = chatAsInt(event['client_msg_id']);
      final message = event['message'];
      final pending =
          clientMsgId == null ? null : _pendingTextSends.remove(clientMsgId);
      if (pending != null &&
          !pending.completer.isCompleted &&
          message is Map) {
        pending.completer.complete(
          Map<String, dynamic>.from(message),
        );
      }
      return true;
    }
    if (ev == 'chat_send_error') {
      final clientMsgId = chatAsInt(event['client_msg_id']);
      final pending =
          clientMsgId == null ? null : _pendingTextSends.remove(clientMsgId);
      if (pending != null && !pending.completer.isCompleted) {
        final detail = event['detail'];
        pending.completer.completeError(
          StateError(detail?.toString() ?? 'chat_send_error'),
        );
      }
      return true;
    }
    return false;
  }

  bool _handleMarkReadAckEvent(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev != 'chat_mark_read_ack') return false;
    final threadId = chatAsInt(event['thread_id']);
    final pending =
        threadId == null ? null : _pendingMarkReads.remove(threadId);
    if (pending != null && !pending.isCompleted) {
      pending.complete(event['ok'] == true);
    }
    return true;
  }

  void _failPendingMarkReads() {
    for (final entry in _pendingMarkReads.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(false);
      }
    }
    _pendingMarkReads.clear();
  }

  void _failPendingTextSends() {
    for (final entry in _pendingTextSends.entries) {
      if (!entry.value.completer.isCompleted) {
        entry.value.completer.completeError(
          StateError('websocket disconnected'),
        );
      }
    }
    _pendingTextSends.clear();
  }
}

class _PendingWsTextSend {
  _PendingWsTextSend({required this.completer});

  final Completer<Map<String, dynamic>> completer;
}
