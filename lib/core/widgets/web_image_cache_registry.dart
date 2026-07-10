import 'package:flutter/foundation.dart';

/// Уведомляет web-виджеты об изображениях, попавших в общий кэш после async-загрузки.
abstract final class WebImageCacheRegistry {
  static final Map<String, ValueNotifier<int>> _revisions = {};

  static ValueNotifier<int> _notifier(String key) {
    return _revisions.putIfAbsent(key, () => ValueNotifier(0));
  }

  static ValueListenable<int> listenable(String key) => _notifier(key);

  static void notifyUpdated(String key) {
    final notifier = _notifier(key);
    notifier.value = notifier.value + 1;
  }

  static String avatarKey(int userId) => 'avatar:$userId';

  static String attachmentKey(int threadId, int attachmentId) =>
      'attachment:$threadId:$attachmentId';
}
