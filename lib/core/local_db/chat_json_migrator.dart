import 'package:flutter/foundation.dart';

import '../cache/familychat_local_cache.dart';
import 'chat_database.dart';

/// One-shot migrate of JSON message/thread cache into SQLite.
abstract final class ChatJsonMigrator {
  static Future<void> migrateIfNeeded(ChatDatabase db) async {
    if (!ChatDatabase.isSupported) return;
    final done = await db.metaGet(ChatDatabase.metaMigratedFromJson);
    if (done == '1') return;

    try {
      final threads = await FamilyChatLocalCache.readChatThreads();
      if (threads != null && threads.isNotEmpty) {
        await db.replaceThreads(threads);
        for (final thread in threads) {
          final threadId = thread['id'];
          final id = threadId is int ? threadId : int.tryParse('$threadId');
          if (id == null) continue;
          final messages = await FamilyChatLocalCache.readThreadMessages(id);
          if (messages == null || messages.isEmpty) continue;
          await db.upsertMessages(id, messages);
        }
      }

      final members = await FamilyChatLocalCache.readChatMembers();
      if (members != null && members.isNotEmpty) {
        await db.replaceMembers(members);
      }
    } catch (e, st) {
      debugPrint('[ChatJsonMigrator] failed: $e\n$st');
    }

    await db.metaSet(ChatDatabase.metaMigratedFromJson, '1');
  }
}