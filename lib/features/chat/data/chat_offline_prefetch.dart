import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/cache/familychat_media_cache.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_realtime_utils.dart';

/// Фоновая загрузка списка чатов и последних сообщений для офлайн-режима.
abstract final class ChatOfflinePrefetch {
  static Future<void> run(FamilyChatRepository repo) async {
    try {
      final results = await Future.wait([
        repo.chatThreads(),
        repo.members(),
      ]);
      final threads = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      await FamilyChatLocalCache.saveChatThreads(threads);
      await FamilyChatLocalCache.saveChatMembers(members);

      for (final thread in threads) {
        final threadId = chatAsInt(thread['id']);
        if (threadId == null) continue;
        try {
          final page = await repo.threadMessages(threadId, limit: 30);
          await FamilyChatLocalCache.saveThreadMessages(threadId, page.messages);
          await _prefetchMessageMedia(repo, threadId, page.messages);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> _prefetchMessageMedia(
    FamilyChatRepository repo,
    int threadId,
    List<Map<String, dynamic>> messages,
  ) async {
    for (final message in messages) {
      for (final attachment in chatAttachmentsOf(message)) {
        if (attachment['kind']?.toString() != 'image') continue;
        final attachmentId = chatAsInt(attachment['id']);
        if (attachmentId == null) continue;

        if (kIsWeb) {
          try {
            final existing = await FamilyChatLocalCache.readAttachmentBytes(
              threadId,
              attachmentId,
            );
            if (existing != null && existing.isNotEmpty) continue;
            final bytes = await repo.fetchChatAttachmentBytes(threadId, attachmentId);
            await FamilyChatLocalCache.saveAttachmentBytes(
              threadId,
              attachmentId,
              bytes,
            );
          } catch (_) {}
          continue;
        }

        final url = attachment['file_url']?.toString() ?? '';
        if (url.isEmpty) continue;
        try {
          await FamilyChatMediaCache.preview.downloadFile(url);
        } catch (_) {}
      }
    }
    if (!kIsWeb) {
      unawaited(FamilyChatMediaCache.trimIfNeeded());
    }
  }
}
