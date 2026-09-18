import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_handler/share_handler.dart';

import 'share_favorite_chats_store.dart';

/// Direct share: отдельные чаты в системном «Поделиться» (Android) + intent donation (iOS).
abstract final class ShareDirectTargetService {
  ShareDirectTargetService._();

  static const _channel = MethodChannel('com.familychat/share_targets');
  static const conversationIdPrefix = 'familychat_thread_';

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static String conversationIdForThread(int threadId) =>
      '$conversationIdPrefix$threadId';

  static int? threadIdFromConversationId(String? raw) {
    final id = raw?.trim() ?? '';
    if (id.isEmpty) return null;
    if (id.startsWith(conversationIdPrefix)) {
      return int.tryParse(id.substring(conversationIdPrefix.length));
    }
    final match = RegExp(r'(\d+)$').firstMatch(id);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static Future<void> syncFromStore() async {
    if (!isSupported) return;
    final favorites = await ShareFavoriteChatsStore.topFavorites();
    await _publish(favorites);
  }

  /// Сид ярлыков из списка чатов (избранные для шаринга + недавние треды).
  static Future<void> syncFromThreads(
    List<Map<String, dynamic>> threads, {
    Map<int, Map<String, dynamic>> memberByUserId = const {},
  }) async {
    if (!isSupported) return;
    final favorites = await ShareFavoriteChatsStore.topFavorites(limit: 12);
    await ShareFavoriteChatsStore.mergeThreadMetadata(threads, memberByUserId);

    final candidates = <ShareFavoriteChatEntry>[];
    final seen = <int>{};

    void add(ShareFavoriteChatEntry entry) {
      if (entry.threadId <= 0 || seen.contains(entry.threadId)) return;
      seen.add(entry.threadId);
      candidates.add(entry);
    }

    for (final fav in favorites) {
      add(fav);
    }

    for (final thread in threads) {
      if (candidates.length >= ShareFavoriteChatsStore.directShareLimit) break;
      final entry = ShareFavoriteChatsStore.entryFromThread(
        thread,
        memberByUserId,
      );
      if (entry == null) continue;
      add(entry);
    }

    await _publish(
      candidates.take(ShareFavoriteChatsStore.directShareLimit).toList(),
    );
  }

  /// Донат после реальной отправки — так iOS лучше показывает чат в шторке.
  static Future<void> recordConversationUse({
    required int threadId,
    required String title,
    String? avatarFilePath,
  }) async {
    if (!isSupported || threadId <= 0) return;
    final name = title.trim().isEmpty ? 'Чат' : title.trim();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await ShareHandlerPlatform.instance.recordSentMessage(
          conversationIdentifier: conversationIdForThread(threadId),
          conversationName: name,
          conversationImageFilePath: avatarFilePath,
          serviceName: 'Family Space',
        );
      } catch (e) {
        debugPrint('[ShareDirectTarget] recordSentMessage failed: $e');
      }
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<void>('reportShareShortcutUsed', {
          'thread_id': threadId,
        });
      } catch (e) {
        debugPrint('[ShareDirectTarget] reportShortcutUsed failed: $e');
      }
    }
  }

  static Future<void> _publish(List<ShareFavoriteChatEntry> chats) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (final chat in chats) {
        await recordConversationUse(
          threadId: chat.threadId,
          title: chat.title,
        );
      }
      // Дублируем через наш channel (metadata / cleanup).
      try {
        await _channel.invokeMethod<void>('syncShareShortcuts', {
          'chats': chats
              .map(
                (e) => {
                  'thread_id': e.threadId,
                  'title': e.title,
                  if (e.avatarUrl != null) 'avatar_url': e.avatarUrl,
                },
              )
              .toList(),
        });
      } catch (e) {
        debugPrint('[ShareDirectTarget] iOS channel sync failed: $e');
      }
      return;
    }

    try {
      await _channel.invokeMethod<void>('syncShareShortcuts', {
        'chats': chats
            .map(
              (e) => {
                'thread_id': e.threadId,
                'title': e.title,
                if (e.avatarUrl != null) 'avatar_url': e.avatarUrl,
              },
            )
            .toList(),
      });
    } catch (e) {
      debugPrint('[ShareDirectTarget] sync failed: $e');
    }
  }

  /// Чат из ярлыка direct share (Android extras или iOS conversationIdentifier).
  static Future<int?> takePendingDirectShareThreadId({
    String? conversationIdentifier,
  }) async {
    if (!isSupported) return null;
    final fromMedia = threadIdFromConversationId(conversationIdentifier);
    if (fromMedia != null) return fromMedia;
    try {
      final raw = await _channel.invokeMethod<dynamic>('takePendingDirectShare');
      if (raw is Map) {
        final id = int.tryParse(raw['thread_id']?.toString() ?? '');
        return id;
      }
    } catch (e) {
      debugPrint('[ShareDirectTarget] takePending failed: $e');
    }
    return null;
  }
}
