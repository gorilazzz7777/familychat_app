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

  /// Pinned messages for the thread (Telegram-style bar).
  Future<List<Map<String, dynamic>>> loadPinnedMessages(int threadId) async =>
      const [];

  Future<List<Map<String, dynamic>>> pinMessage({
    required int threadId,
    required int messageId,
  }) async =>
      loadPinnedMessages(threadId);

  Future<List<Map<String, dynamic>>> unpinMessage({
    required int threadId,
    required int messageId,
  }) async =>
      loadPinnedMessages(threadId);

  /// Hard-delete own messages for everyone.
  Future<List<int>> deleteMessages({
    required int threadId,
    required List<int> messageIds,
  }) async =>
      messageIds;

  /// Remove messages only from the current user's history.
  Future<List<int>> hideMessagesForMe({
    required int threadId,
    required List<int> messageIds,
  }) async =>
      messageIds;

  /// Compose a message draft with AI (task + thread context on server).
  Future<String> aiComposeMessage({
    required int threadId,
    required String task,
  }) async {
    throw UnimplementedError('aiComposeMessage');
  }

  /// Server TTS for message body / voice transcript. Returns WAV bytes.
  Future<List<int>> speakMessages({
    required int threadId,
    required List<int> messageIds,
  }) async {
    throw UnimplementedError('speakMessages');
  }
}
