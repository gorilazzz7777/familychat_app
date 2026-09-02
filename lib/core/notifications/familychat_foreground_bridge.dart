import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../features/chat/data/active_chat_context.dart';

/// Поднять Activity на передний план без дополнительных разрешений у пользователя.
class FamilyChatForegroundBridge {
  FamilyChatForegroundBridge._();

  static const _channel = MethodChannel('com.familychat/lifecycle');

  static bool get _shouldUseAndroidBridge =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool isAppInBackground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
  }

  /// Приложение на экране и активно — не показываем push (realtime через WebSocket).
  static bool isAppInForeground() {
    return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  /// Чат открыт и пользователь реально смотрит на него (не свёрнуто в фон).
  static bool isActivelyViewingThread(int threadId) {
    return ActiveChatContext.instance.isViewingThread(threadId) &&
        isAppInForeground();
  }

  static Future<void> bringToForegroundIfNeeded({bool forCall = false}) async {
    if (!_shouldUseAndroidBridge || !isAppInBackground()) return;
    try {
      await _channel.invokeMethod<void>(
        'bringToForeground',
        <String, dynamic>{'forCall': forCall},
      );
    } catch (e) {
      debugPrint('bringToForeground failed: $e');
    }
  }
}
