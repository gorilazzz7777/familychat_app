import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Показ поверх блокировки только на время входящего/активного звонка.
class CallLockScreen {
  CallLockScreen._();

  static const _channel = MethodChannel('com.familychat/lifecycle');
  static int _holds = 0;

  static Future<void> acquire() async {
    if (kIsWeb) return;
    _holds += 1;
    if (_holds == 1) {
      try {
        await _channel.invokeMethod<void>('setShowOnLockScreen', true);
      } catch (e) {
        debugPrint('setShowOnLockScreen(true) failed: $e');
      }
    }
  }

  static Future<void> release() async {
    if (kIsWeb) return;
    if (_holds <= 0) return;
    _holds -= 1;
    if (_holds == 0) {
      try {
        await _channel.invokeMethod<void>('setShowOnLockScreen', false);
      } catch (e) {
        debugPrint('setShowOnLockScreen(false) failed: $e');
      }
    }
  }
}
