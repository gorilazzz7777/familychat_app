import 'chat_realtime_utils.dart';
import 'chat_send_trace.dart';
import 'familychat_realtime.dart';

/// Plain-text send eligibility and WS transport helpers.
abstract final class ChatWsTextSend {
  static const ackTimeout = Duration(seconds: 2);

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
    final realtime = FamilyChatRealtime.instance;
    if (!realtime.isConnected) {
      ChatSendTrace.log(
        'ws_not_connected',
        threadId: threadId,
        tempId: clientMsgId,
        source: 'ws',
      );
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
      ChatSendTrace.log(
        ack == null ? 'ws_ack_timeout' : 'ws_ack_ok',
        threadId: threadId,
        tempId: clientMsgId,
        serverId: ack == null ? null : chatAsInt(ack['id']),
        source: 'ws',
      );
      return ack;
    } catch (e) {
      ChatSendTrace.log(
        'ws_ack_error',
        threadId: threadId,
        tempId: clientMsgId,
        source: 'ws',
        detail: '$e',
      );
      return null;
    }
  }

  static Future<void> ensureConnection() async {
    final realtime = FamilyChatRealtime.instance;
    if (realtime.isConnected) return;
    await realtime.reconnectAndRefresh();
  }
}
