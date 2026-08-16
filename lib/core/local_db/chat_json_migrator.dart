import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../cache/familychat_local_cache.dart';
import 'chat_database.dart';

/// One-shot migrate of JSON caches into SQLite (threads/messages/outbox/media).
abstract final class ChatJsonMigrator {
  static Future<void> migrateIfNeeded(ChatDatabase db) async {
    await _migrateThreadsMembers(db);
    await _migrateOutbox(db);
    await _migrateMediaIndex(db);
  }

  static Future<void> _migrateThreadsMembers(ChatDatabase db) async {
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
      debugPrint('[ChatJsonMigrator] threads/members failed: $e\n$st');
    }

    await db.metaSet(ChatDatabase.metaMigratedFromJson, '1');
  }

  static Future<void> _migrateOutbox(ChatDatabase db) async {
    final done = await db.metaGet(ChatDatabase.metaMigratedOutbox);
    if (done == '1') return;

    try {
      final items = await FamilyChatLocalCache.readOutboxItems();
      if (items.isNotEmpty) {
        await db.writeOutboxItems(items);
        for (final item in items) {
          final rawAttachments = item['attachments'];
          if (rawAttachments is! List) continue;
          for (final raw in rawAttachments) {
            if (raw is! Map) continue;
            final storageKey = raw['storage_key']?.toString();
            if (storageKey == null || storageKey.isEmpty) continue;
            final bytes =
                await FamilyChatLocalCache.readOutboxBytes(storageKey);
            if (bytes == null || bytes.isEmpty) continue;
            await db.saveOutboxBlob(storageKey, bytes);
          }
        }
      }
    } catch (e, st) {
      debugPrint('[ChatJsonMigrator] outbox failed: $e\n$st');
    }

    await db.metaSet(ChatDatabase.metaMigratedOutbox, '1');
  }

  static Future<void> _migrateMediaIndex(ChatDatabase db) async {
    final done = await db.metaGet(ChatDatabase.metaMigratedMediaIndex);
    if (done == '1') return;

    try {
      // Prefer legacy blob in meta; fall back to JSON web cache.
      Map<String, dynamic>? raw;
      final encoded = await db.metaGet('media_local_index_v1');
      if (encoded != null && encoded.isNotEmpty) {
        raw = jsonDecode(encoded) as Map<String, dynamic>;
      } else {
        raw = await FamilyChatLocalCache.readJson('media_local_index');
      }
      if (raw != null && raw.isNotEmpty) {
        final mapped = <String, Map<String, dynamic>>{};
        for (final entry in raw.entries) {
          if (entry.key == 'cached_at') continue;
          if (entry.value is! Map) continue;
          mapped[entry.key] =
              Map<String, dynamic>.from(entry.value as Map);
        }
        if (mapped.isNotEmpty) {
          await db.replaceAllMediaIndex(mapped);
        }
      }
    } catch (e, st) {
      debugPrint('[ChatJsonMigrator] media index failed: $e\n$st');
    }

    await db.metaSet(ChatDatabase.metaMigratedMediaIndex, '1');
  }
}
