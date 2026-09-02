import 'familychat_realtime.dart';

/// Mark-read transport: WebSocket first, HTTP fallback elsewhere.
abstract final class ChatWsMarkRead {
  static const ackTimeout = Duration(seconds: 3);

  static Future<bool> tryMarkRead({
    required int threadId,
    required int lastMessageId,
  }) async {
    if (threadId <= 0 || lastMessageId <= 0) return false;
    final realtime = FamilyChatRealtime.instance;
    if (!realtime.isConnected) return false;
    return realtime.sendMarkRead(
      threadId: threadId,
      lastMessageId: lastMessageId,
      timeout: ackTimeout,
    );
  }
}
