import 'dart:async';

import 'chat_realtime_utils.dart';
import 'chat_send_trace.dart';
import 'familychat_realtime.dart';

/// Plain-text send eligibility and WS transport helpers.
abstract final class ChatWsTextSend {
  /// Wait this long for WS ack before falling back to HTTP outbox.
  static const ackTimeout = Duration(seconds: 5);

  /// Await reconnect this long before deciding the socket is unavailable.
  static const reconnectTimeout = Duration(seconds: 5);

  /// After consecutive WS ack failures, skip WS and use HTTP outbox for a while.
  /// Avoids stacking timeouts on every rapid send when the socket is half-dead.
  static const int _circuitFailThreshold = 2;
  static const Duration _circuitOpenFor = Duration(seconds: 20);

  static int _consecutiveFailures = 0;
  static DateTime? _circuitOpenUntil;
  static bool _listeningRealtime = false;

  /// One shared reconnect attempt — parallel Send share this Future.
  static Future<bool>? _inFlightReconnect;

  /// Serialize plain-text sends so rapid taps keep order (WS or outbox).
  static Future<void> _sendGate = Future<void>.value();

  static bool isEligible({
    required List<dynamic> attachments,
    int? voiceDurationMs,
    String? voiceTranscript,
    int? videoNoteDurationMs,
  }) {
    if (attachments.isNotEmpty) return false;
    if (voiceDurationMs != null) return false;
    if (voiceTranscript != null && voiceTranscript.trim().isNotEmpty) {
      return false;
    }
    if (videoNoteDurationMs != null) return false;
    return true;
  }

  static bool get _circuitOpen {
    final until = _circuitOpenUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _circuitOpenUntil = null;
    return false;
  }

  static void _ensureRealtimeListener() {
    if (_listeningRealtime) return;
    _listeningRealtime = true;
    FamilyChatRealtime.instance.addListener((event) {
      if (event['event']?.toString() == 'ws_connected') {
        _noteSuccess();
      }
    });
  }

  static void _noteSuccess() {
    _consecutiveFailures = 0;
    _circuitOpenUntil = null;
  }

  static void _noteFailure() {
    _consecutiveFailures += 1;
    if (_consecutiveFailures >= _circuitFailThreshold) {
      _circuitOpenUntil = DateTime.now().add(_circuitOpenFor);
      ChatSendTrace.log(
        'ws_circuit_open',
        source: 'ws',
        detail:
            'failures=$_consecutiveFailures openFor=${_circuitOpenFor.inSeconds}s',
      );
    }
  }

  /// Run [action] after previous plain-text sends finish (FIFO).
  static Future<T> runExclusive<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _sendGate = _sendGate.then((_) async {
      try {
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    // Keep the gate alive even if [action] threw.
    _sendGate = _sendGate.catchError((_) {});
    return done.future;
  }

  static Future<Map<String, dynamic>?> trySend({
    required int threadId,
    required int clientMsgId,
    required String body,
    int? replyToMessageId,
    List<int> mentionedUserIds = const [],
    bool notifySilent = false,
  }) async {
    _ensureRealtimeListener();
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    if (_circuitOpen) {
      ChatSendTrace.log(
        'ws_circuit_skip',
        threadId: threadId,
        tempId: clientMsgId,
        source: 'ws',
      );
      return null;
    }
    final realtime = FamilyChatRealtime.instance;
    if (!realtime.isConnected) {
      ChatSendTrace.log(
        'ws_not_connected',
        threadId: threadId,
        tempId: clientMsgId,
        source: 'ws',
      );
      // Soft skip — do not open the circuit for a down socket.
      return null;
    }
    try {
      final ack = await realtime.sendTextMessage(
        threadId: threadId,
        clientMsgId: clientMsgId,
        body: trimmed,
        replyToMessageId: replyToMessageId,
        mentionedUserIds: mentionedUserIds,
        notifySilent: notifySilent,
        timeout: ackTimeout,
      );
      if (ack == null) {
        ChatSendTrace.log(
          'ws_ack_timeout',
          threadId: threadId,
          tempId: clientMsgId,
          source: 'ws',
        );
        _noteFailure();
        return null;
      }
      ChatSendTrace.log(
        'ws_ack_ok',
        threadId: threadId,
        tempId: clientMsgId,
        serverId: chatAsInt(ack['id']),
        source: 'ws',
      );
      _noteSuccess();
      return ack;
    } catch (e) {
      ChatSendTrace.log(
        'ws_ack_error',
        threadId: threadId,
        tempId: clientMsgId,
        source: 'ws',
        detail: '$e',
      );
      _noteFailure();
      return null;
    }
  }

  /// Await a short reconnect window. Parallel callers share one attempt.
  ///
  /// Also waits for an in-flight `connect` (auto-reconnect) via `ws_connected`,
  /// so we do not bail early when `_connecting` caused `connect()` to no-op.
  static Future<bool> ensureConnection({
    Duration timeout = reconnectTimeout,
  }) async {
    _ensureRealtimeListener();
    final realtime = FamilyChatRealtime.instance;
    if (realtime.isConnected) return true;

    final existing = _inFlightReconnect;
    if (existing != null) {
      try {
        return await existing.timeout(
          timeout,
          onTimeout: () => realtime.isConnected,
        );
      } catch (_) {
        return realtime.isConnected;
      }
    }

    late final Future<bool> future;
    future = _reconnectOnce(timeout).whenComplete(() {
      if (identical(_inFlightReconnect, future)) {
        _inFlightReconnect = null;
      }
    });
    _inFlightReconnect = future;
    return future;
  }

  static Future<bool> _reconnectOnce(Duration timeout) async {
    final realtime = FamilyChatRealtime.instance;
    if (realtime.isConnected) return true;

    final connected = Completer<bool>();
    void onEvent(Map<String, dynamic> event) {
      if (event['event']?.toString() != 'ws_connected') return;
      if (!connected.isCompleted) connected.complete(true);
    }

    realtime.addListener(onEvent);
    try {
      // Kick refresh+connect (may no-op if already connecting — then we wait).
      unawaited(realtime.reconnectAndRefresh());
      if (realtime.isConnected) return true;

      final result = await Future.any<bool>([
        connected.future,
        Future<bool>.delayed(timeout, () => realtime.isConnected),
      ]);
      return result || realtime.isConnected;
    } finally {
      realtime.removeListener(onEvent);
    }
  }
}
