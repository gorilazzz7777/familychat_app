/// Backend-facing chat operations. Each app implements against its API namespace.
///
/// Payloads stay as `Map<String, dynamic>` for now (same shape as Family Chat /
/// TeamCoach serializers) so adapters can map without a full DTO rewrite.
abstract class ChatRepository {
  Future<List<Map<String, dynamic>>> loadMessages({
    required int threadId,
    int? beforeId,
    int limit = 50,
  });

  Future<Map<String, dynamic>> sendText({
    required int threadId,
    required String body,
    int? replyToId,
  });

  Future<Map<String, dynamic>> sendAttachment({
    required int threadId,
    required List<int> bytes,
    required String filename,
    String? contentType,
    String? caption,
  });

  Future<void> markRead({required int threadId, required int lastReadMessageId});
}
