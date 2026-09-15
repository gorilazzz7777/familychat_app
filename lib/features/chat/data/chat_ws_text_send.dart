import 'chat_realtime_utils.dart';
import 'chat_send_trace.dart';
import 'familychat_realtime.dart';

/// Plain-text send eligibility and WS transport helpers.
abstract final class ChatWsTextSend {
  static const ackTimeout = Duration(seconds: 2);

  /// After consecutive WS ack failures, skip WS and use HTTP outbox for a while.
  /// Avoids stacking 2s timeouts on every rapid send when the socket is half-dead.
  static const int _circuitFailThreshold = 2;
  static const Duration _circuitOpenFor = Duration(seconds: 45);

  static int _consecutiveFailures = 0;
  static DateTime? _circuitOpenUntil;

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
        detail: 'failures=$_consecutiveFailures openFor=${_circuitOpenFor.inSeconds}s',
      );
    }
  }

  static Future<Map<String, dynamic>?> trySend({
    required int threadId,
    required int clientMsgId,
    required String body,
    int? replyToMessageId,
    List<int> mentionedUserIds = const [],
    bool notifySilent = false,
  }) async {
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
      _noteFailure();
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

  /// Best-effort reconnect; never block the send path for long.
  static Future<void> ensureConnection() async {
    final realtime = FamilyChatRealtime.instance;
    if (realtime.isConnected) return;
    try {
      await realtime.reconnectAndRefresh().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
