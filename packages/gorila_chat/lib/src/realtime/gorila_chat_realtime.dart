import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../util/chat_realtime_utils.dart';

typedef GorilaChatRealtimeHandler = void Function(Map<String, dynamic> event);

/// Resolves a fresh access token before WS connect / reconnect.
/// [force] — always hit refresh (used after disconnect / auth failure).
typedef GorilaChatAccessTokenResolver = Future<String?> Function({
  bool force,
});

/// Shared chat WebSocket client (Family Chat reference behaviour):
/// reconnect with backoff, normalize payloads, synthetic `chat_refresh`.
class GorilaChatRealtime {
  GorilaChatRealtime({
    required this.debugName,
    required this.uriForToken,
    GorilaChatAccessTokenResolver? resolveAccessToken,
  }) : _resolveAccessToken = resolveAccessToken;

  final String debugName;
  final Uri Function(String accessToken) uriForToken;
  GorilaChatAccessTokenResolver? _resolveAccessToken;

  /// Bind / replace the JWT resolver (app wires AuthTokenRefresher here).
  void setAccessTokenResolver(GorilaChatAccessTokenResolver? resolver) {
    _resolveAccessToken = resolver;
  }

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _listeners = <GorilaChatRealtimeHandler>{};
  String? _accessToken;
  /// Latest token requested while a connect was already in flight.
  String? _queuedConnectToken;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _connecting = false;
  bool _connected = false;
  /// Skip `ws_disconnected` while [connect] intentionally closes the channel.
  bool _intentionalClose = false;
  /// True when the next successful [connect] should emit `chat_refresh`
  /// (after drop / backoff reconnect — open chats must HTTP-resync).
  bool _refreshAfterConnect = false;
  final Map<int, _PendingWsTextSend> _pendingTextSends = {};
  final Map<int, Completer<bool>> _pendingMarkReads = {};

  static const _defaultSendAckTimeout = Duration(seconds: 5);
  static const _defaultMarkReadAckTimeout = Duration(seconds: 3);

  bool get isConnected => _connected && _channel != null;

  void _log(String message, {Object? error, StackTrace? stackTrace}) {
    final line = '[$debugName] $message';
    // ignore: avoid_print — always-on WS diagnostics (iOS Console / Xcode)
    print(line);
    developer.log(
      message,
      name: debugName,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static String redactWsUri(Uri uri) {
    final params = Map<String, String>.from(uri.queryParameters);
    if (params.containsKey('token')) {
      final raw = params['token'] ?? '';
      params['token'] =
          raw.isEmpty ? '***' : '***len=${raw.length}';
    }
    return uri.replace(queryParameters: params).toString();
  }

  void addListener(GorilaChatRealtimeHandler handler) => _listeners.add(handler);

  void removeListener(GorilaChatRealtimeHandler handler) =>
      _listeners.remove(handler);

  void emitSyntheticEvent(Map<String, dynamic> event) {
    _dispatch(chatNormalizeMap(Map<dynamic, dynamic>.from(event)));
  }

  Future<String?> _freshAccessToken({
    String? preferred,
    bool force = false,
  }) async {
    final resolver = _resolveAccessToken;
    if (resolver != null) {
      try {
        final resolved = await resolver(force: force);
        if (resolved != null && resolved.isNotEmpty) return resolved;
      } catch (e, st) {
        _log('ws token resolve failed: $e', error: e, stackTrace: st);
      }
    }
    if (!force && preferred != null && preferred.isNotEmpty) return preferred;
    if (!force) {
      final cached = _accessToken;
      if (cached != null && cached.isNotEmpty) return cached;
    }
    return null;
  }

  Future<void> connect(String accessToken) async {
    // Always re-resolve when possible so callers with a stale string still
    // open WS with a valid JWT.
    final resolved = await _freshAccessToken(preferred: accessToken);
    final token = (resolved != null && resolved.isNotEmpty)
        ? resolved
        : accessToken;
    if (token.isEmpty) {
      _log('ws connect skipped: empty access token');
      return;
    }
    // Anti-flap: ignore rapid reconnects while already connected with same token.
    if (_connected &&
        _accessToken == token &&
        _reconnectAttempt == 0 &&
        !_refreshAfterConnect) {
      _log('ws connect skipped: already connected');
      return;
    }
    _accessToken = token;
    _reconnectTimer?.cancel();
    if (_connecting) {
      // Latest token wins once the in-flight connect finishes.
      _queuedConnectToken = token;
      _log('ws connect queued: already connecting');
      return;
    }
    _connecting = true;
    _queuedConnectToken = null;
    try {
      _intentionalClose = true;
      await _closeChannel();
      _intentionalClose = false;
      final uri = uriForToken(token);
      _log(
        'ws connecting attempt=$_reconnectAttempt '
        'uri=${redactWsUri(uri)}',
      );
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
          } catch (e, st) {
            _log('ws decode error: $e', error: e, stackTrace: st);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _log('ws stream error: $error', error: error, stackTrace: stackTrace);
          _handleTransportLost();
        },
        onDone: () {
          _log('ws stream done (closed by peer or local)');
          _handleTransportLost();
        },
        cancelOnError: false,
      );
      try {
        await _channel!.ready.timeout(const Duration(seconds: 20));
        _connected = true;
        _reconnectAttempt = 0;
        _log('ws connected OK');
        emitSyntheticEvent({'event': 'ws_connected'});
        if (_refreshAfterConnect) {
          _refreshAfterConnect = false;
          emitSyntheticEvent({'event': 'chat_refresh', 'force': true});
        }
      } catch (e, st) {
        _log('ws ready/connect failed: $e', error: e, stackTrace: st);
        _connected = false;
        await _closeChannel();
        _scheduleReconnect();
      }
    } catch (e, st) {
      _log('ws connect error: $e', error: e, stackTrace: st);
      _connected = false;
      _scheduleReconnect();
    } finally {
      _intentionalClose = false;
      _connecting = false;
      final queued = _queuedConnectToken;
      _queuedConnectToken = null;
      if (queued != null && queued.isNotEmpty) {
        if (!isConnected || queued != _accessToken) {
          unawaited(connect(queued));
        }
      }
    }
  }

  void _handleTransportLost() {
    final wasConnected = _connected;
    _connected = false;
    _failPendingTextSends();
    _failPendingMarkReads();
    if (wasConnected && !_intentionalClose) {
      _log('ws transport lost → schedule reconnect');
      emitSyntheticEvent({'event': 'ws_disconnected'});
    }
    _scheduleReconnect();
  }

  void _dispatch(Map<String, dynamic> event) {
    for (final handler in _listeners) {
      handler(event);
    }
  }

  void _scheduleReconnect() {
    final hasCached = _accessToken != null && _accessToken!.isNotEmpty;
    final hasResolver = _resolveAccessToken != null;
    if (!hasCached && !hasResolver) return;
    _refreshAfterConnect = true;
    _reconnectTimer?.cancel();
    final seconds = math.min(30, math.pow(2, _reconnectAttempt).toInt());
    _reconnectAttempt++;
    _log('ws reconnect scheduled in ${seconds}s attempt=$_reconnectAttempt');
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(() async {
        // Force refresh after drop — cached JWT often already rejected (WS 403).
        final token = await _freshAccessToken(force: true);
        if (token == null || token.isEmpty) {
          _log('ws reconnect skipped: no access token');
          return;
        }
        await connect(token);
      }());
    });
  }

  Future<void> disconnect() async {
    _log('ws disconnect requested');
    _accessToken = null;
    _queuedConnectToken = null;
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
  ///
  /// Always prefers a freshly resolved JWT when [setAccessTokenResolver] is set,
  /// so background reconnects do not reuse an expired in-memory token.
  Future<void> reconnectAndRefresh() async {
    final token = await _freshAccessToken(force: true);
    _log(
      'ws reconnectAndRefresh hasToken=${token != null && token.isNotEmpty}',
    );
    if (token != null && token.isNotEmpty) {
      await connect(token);
    }
    emitSyntheticEvent({'event': 'chat_refresh', 'force': true});
  }

  void sendJson(Map<String, dynamic> payload) {
    final channel = _channel;
    if (!_connected || channel == null) {
      _log(
        'ws sendJson dropped (not connected) event=${payload['event']}',
      );
      return;
    }
    try {
      channel.sink.add(jsonEncode(payload));
    } catch (e, st) {
      _log('ws sendJson error: $e', error: e, stackTrace: st);
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
    if (!isConnected) {
      _log(
        'ws sendText skipped: not connected '
        'thread=$threadId clientMsgId=$clientMsgId',
      );
      return null;
    }
    final trimmed = body?.trim() ?? '';
    if (trimmed.isEmpty) return null;

    _log(
      'ws sendText → thread=$threadId clientMsgId=$clientMsgId '
      'bodyLen=${trimmed.length} timeoutMs=${timeout.inMilliseconds}',
    );
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
      final ack = await completer.future.timeout(timeout);
      _log(
        'ws sendText ack OK thread=$threadId clientMsgId=$clientMsgId '
        'serverId=${chatAsInt(ack['id'])}',
      );
      return ack;
    } catch (e) {
      _pendingTextSends.remove(clientMsgId);
      _log(
        'ws sendText ack FAIL thread=$threadId clientMsgId=$clientMsgId err=$e',
      );
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
      } else {
        _log(
          'ws chat_send_ack unmatched clientMsgId=$clientMsgId '
          'hadPending=${pending != null}',
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
    final n = _pendingTextSends.length;
    if (n > 0) {
      _log('ws fail $n pending text sends (disconnect)');
    }
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
