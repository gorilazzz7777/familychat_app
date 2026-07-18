/// Backend-facing chat operations. Each app implements against its API namespace.
///
/// Payloads stay as `Map<String, dynamic>` (Family Chat / TeamCoach serializers).
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
    List<int>? attachmentIds,
  });

  Future<Map<String, dynamic>> sendAttachment({
    required int threadId,
    required List<int> bytes,
    required String filename,
    String? contentType,
    String? caption,
  });

  Future<void> markRead({
    required int threadId,
    required int lastReadMessageId,
  });

  /// Current user id for bubble alignment; null if unknown.
  Future<int?> currentUserId();

  Future<List<Map<String, dynamic>>> threadMedia(int threadId) async =>
      const [];

  Future<List<Map<String, dynamic>>> threadLinks(int threadId) async =>
      const [];

  Future<List<Map<String, dynamic>>> threadMembers(int threadId) async =>
      const [];

  Future<bool> notificationsEnabled({
    required int threadId,
    String? kind,
    int? peerUserId,
  }) async =>
      true;

  Future<bool> setNotificationsEnabled({
    required int threadId,
    required bool enabled,
    String? kind,
    int? peerUserId,
  }) async =>
      enabled;

  Future<Map<String, dynamic>?> resolvePeerProfile(int userId) async => null;
}
