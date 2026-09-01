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
    if (!realtime.isConnected) return null;
    try {
      return await realtime.sendTextMessage(
        threadId: threadId,
        clientMsgId: clientMsgId,
        body: trimmed,
        replyToMessageId: replyToMessageId,
        mentionedUserIds: mentionedUserIds,
        notifySilent: notifySilent,
        timeout: ackTimeout,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> ensureConnection() async {
    final realtime = FamilyChatRealtime.instance;
    if (realtime.isConnected) return;
    await realtime.reconnectAndRefresh();
  }
}
