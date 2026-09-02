import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'share_favorite_chats_store.dart';

/// Direct share: отдельные чаты в системном «Поделиться» (Android) + intent donation (iOS).
abstract final class ShareDirectTargetService {
  ShareDirectTargetService._();

  static const _channel = MethodChannel('com.familychat/share_targets');

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> syncFromStore() async {
    if (!isSupported) return;
    final favorites = await ShareFavoriteChatsStore.topFavorites();
    if (favorites.isEmpty) {
      try {
        await _channel.invokeMethod<void>('syncShareShortcuts', {'chats': []});
      } catch (e) {
        debugPrint('[ShareDirectTarget] clear shortcuts failed: $e');
      }
      return;
    }
    try {
      await _channel.invokeMethod<void>('syncShareShortcuts', {
        'chats': favorites
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

  /// Чат из ярлыка direct share (если пользователь выбрал конкретный чат в шторке).
  static Future<int?> takePendingDirectShareThreadId() async {
    if (!isSupported) return null;
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
