import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/token_storage.dart';
import '../../familychat/data/familychat_repository.dart';

/// Runs inside FCM background isolate: HTTP-fetch thread into SQLite.
abstract final class ChatBackgroundSync {
  static Future<void> handleRemoteMessage(RemoteMessage message) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return;
    final data = message.data;
    final type = data['type']?.toString() ?? '';
    if (type != 'familychat_chat') return;

    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    if (threadId == null) return;

    try {
      final token = await TokenStorage().readAccess();
      if (token == null || token.isEmpty) {
        debugPrint('[ChatBackgroundSync] no access token');
        return;
      }

      final db = await ChatLocalStore.instance.openWithExecutor();
      if (db == null) return;

      final api = ApiClient();
      final repo = FamilyChatRepository(api);
      final page = await repo.threadMessages(threadId, limit: 50);
      await db.upsertMessages(threadId, page.messages);

      // Soft-update thread preview if we already know the thread.
      final threads = await db.readThreads();
      for (final thread in threads) {
        final id = thread['id'];
        final parsed = id is int ? id : int.tryParse('$id');
        if (parsed != threadId) continue;
        final copy = Map<String, dynamic>.from(thread);
        if (page.messages.isNotEmpty) {
          copy['last_message'] = page.messages.last;
        }
        await db.upsertThread(copy);
        break;
      }

      await db.close();
      debugPrint('[ChatBackgroundSync] synced thread=$threadId msgs=${page.messages.length}');
    } catch (e, st) {
      debugPrint('[ChatBackgroundSync] failed: $e\n$st');
    }
  }
}