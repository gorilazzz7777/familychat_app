import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/local_db/chat_local_store.dart';
import 'chat_realtime_utils.dart';

/// Chat data reads: native uses SQLite, web uses JSON cache.
abstract final class ChatLocalReads {
  static bool get _sqlite => ChatLocalStore.isSupported;

  static Future<List<Map<String, dynamic>>> threads() async {
    if (_sqlite) {
      return ChatLocalStore.instance.readThreads();
    }
    final cached = await FamilyChatLocalCache.readChatThreads();
    return cached ?? const [];
  }

  static Future<List<Map<String, dynamic>>> members() async {
    if (_sqlite) {
      return ChatLocalStore.instance.readMembers();
    }
    final cached = await FamilyChatLocalCache.readChatMembers();
    return cached ?? const [];
  }

  static Future<List<Map<String, dynamic>>> messages(int threadId) async {
    if (_sqlite) {
      return ChatLocalStore.instance.readMessages(threadId);
    }
    final cached = await FamilyChatLocalCache.readThreadMessages(threadId);
    return cached ?? const [];
  }

  static Future<Map<String, dynamic>?> threadById(int threadId) async {
    for (final thread in await threads()) {
      if (chatAsInt(thread['id']) == threadId) return thread;
    }
    return null;
  }

  static Future<void> saveThreadsAndMembers({
    required List<Map<String, dynamic>> threads,
    required List<Map<String, dynamic>> members,
  }) async {
    if (_sqlite) {
      await ChatLocalStore.instance.replaceThreads(threads);
      await ChatLocalStore.instance.replaceMembers(members);
      return;
    }
    await FamilyChatLocalCache.saveChatThreads(threads);
    await FamilyChatLocalCache.saveChatMembers(members);
  }

  static Future<void> saveMembers(List<Map<String, dynamic>> members) async {
    if (_sqlite) {
      await ChatLocalStore.instance.replaceMembers(members);
      return;
    }
    await FamilyChatLocalCache.saveChatMembers(members);
  }
}