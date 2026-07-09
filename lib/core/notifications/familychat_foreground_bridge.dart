import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

  static Future<void> bringToForegroundIfNeeded() async {
    if (!_shouldUseAndroidBridge || !isAppInBackground()) return;
    try {
      await _channel.invokeMethod<void>('bringToForeground');
    } catch (e) {
      debugPrint('bringToForeground failed: $e');
    }
  }
}
