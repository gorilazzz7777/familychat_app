import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../../core/cache/familychat_media_cache.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/media_incoming_sync.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_realtime_utils.dart';

/// Фоновая загрузка списка чатов и последних сообщений для офлайн-режима.
abstract final class ChatOfflinePrefetch {
  /// На web полный файл тяжёлый — не выкачиваем всю ленту заранее.
  static const int _maxPrefetchImagesPerThread = kIsWeb ? 4 : 12;
  static const _secondaryDelay = Duration(seconds: 3);

  static Future<void> run(FamilyChatRepository repo) async {
    try {
      final results = await Future.wait([
        repo.chatThreads(),
        repo.members(),
      ]);
      final threads = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      await ChatLocalStore.instance.replaceThreads(threads);
      await ChatLocalStore.instance.replaceMembers(members);
    } catch (_) {}
  }

  /// Сообщения и медиа — только для указанных чатов (unread / открытый).
  static Future<void> prefetchThreads(
    FamilyChatRepository repo,
    Iterable<int> threadIds,
  ) async {
    final ids = threadIds.toSet();
    if (ids.isEmpty) return;
    try {
      for (final threadId in ids) {
        try {
          final page = await repo.threadMessages(
            threadId,
            limit: FamilyChatLocalCache.maxCachedMessagesPerThread,
          );
          await ChatLocalStore.instance.upsertMessages(
            threadId,
            page.messages,
          );
          unawaited(MediaIncomingSync.ensureMessages(page.messages));
          await prefetchThreadMedia(repo, threadId, page.messages);
        } catch (_) {}
      }
    } catch (_) {}
  }

  @Deprecated('Use run() + prefetchThreads()')
  static Future<void> runWithAllThreadMessages(FamilyChatRepository repo) async {
    try {
      final results = await Future.wait([
        repo.chatThreads(),
        repo.members(),
      ]);
      final threads = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      await ChatLocalStore.instance.replaceThreads(threads);
      await ChatLocalStore.instance.replaceMembers(members);

      for (final thread in threads) {
        final threadId = chatAsInt(thread['id']);
        if (threadId == null) continue;
        try {
          final page = await repo.threadMessages(
            threadId,
            limit: FamilyChatLocalCache.maxCachedMessagesPerThread,
          );
          await ChatLocalStore.instance.upsertMessages(
            threadId,
            page.messages,
          );
          unawaited(MediaIncomingSync.ensureMessages(page.messages));
          await prefetchThreadMedia(repo, threadId, page.messages);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Галерея + текущий месяц календаря — после паузы, чтобы не мешать старту.
  static Future<void> scheduleSecondary(
    FamilyChatRepository repo, {
    int? currentUserId,
  }) async {
    await Future<void>.delayed(_secondaryDelay);
    await runSecondary(repo, currentUserId: currentUserId);
  }

  static Future<void> runSecondary(
    FamilyChatRepository repo, {
    int? currentUserId,
  }) async {
    try {
      final familyAlbums = await repo.familyGalleryAlbums();
      await FamilyChatLocalCache.saveFamilyAlbums(familyAlbums);
    } catch (_) {}

    if (currentUserId != null) {
      try {
        final mine = await repo.memberGalleryAlbums(currentUserId);
        await FamilyChatLocalCache.saveMemberAlbums(currentUserId, mine);
      } catch (_) {}
    }

    try {
      final now = DateTime.now();
      final month = await repo.calendar(year: now.year, month: now.month);
      await FamilyChatLocalCache.saveCalendarMonth(
        year: now.year,
        month: now.month,
        data: month,
      );
    } catch (_) {}
  }

  /// Кладёт превью картинок (входящих и своих) в bin-кэш / MediaCache.
  static Future<void> prefetchThreadMedia(
    FamilyChatRepository repo,
    int threadId,
    List<Map<String, dynamic>> messages, {
    int? maxImages,
  }) =>
      _prefetchMessageMedia(
        repo,
        threadId,
        messages,
        maxImages: maxImages ?? _maxPrefetchImagesPerThread,
      );

  static Future<void> _prefetchMessageMedia(
    FamilyChatRepository repo,
    int threadId,
    List<Map<String, dynamic>> messages, {
    required int maxImages,
  }) async {
    var remaining = maxImages;
    // Свежие сообщения важнее — идём с конца.
    for (final message in messages.reversed) {
      if (remaining <= 0) break;
      for (final attachment in chatAttachmentsOf(message)) {
        if (remaining <= 0) break;
        // Только картинки: полный mp4 в bin-кэш / Image.memory тормозит скролл.
        if (attachment['kind']?.toString() != 'image') continue;
        final attachmentId = chatAsInt(attachment['id']);
        if (attachmentId == null) continue;

        try {
          final existing = await FamilyChatLocalCache.readAttachmentBytes(
            threadId,
            attachmentId,
          );
          if (existing != null && existing.isNotEmpty) {
            if (looksLikeVideoBytes(existing)) continue;
            remaining--;
            continue;
          }
          final bytes =
              await repo.fetchChatAttachmentBytes(threadId, attachmentId);
          await FamilyChatLocalCache.saveAttachmentBytes(
            threadId,
            attachmentId,
            bytes,
          );
          remaining--;
        } catch (_) {}

        // Native: дополнительно греем URL-кэш превью для CachedNetworkImage.
        if (!kIsWeb) {
          final url = attachment['file_url']?.toString() ?? '';
          if (url.isNotEmpty) {
            try {
              await FamilyChatMediaCache.preview.downloadFile(url);
            } catch (_) {}
          }
        }
      }
    }
    if (!kIsWeb) {
      unawaited(FamilyChatMediaCache.trimIfNeeded());
    }
  }
}
