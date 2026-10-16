import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/session_log.dart';

/// Гасит экран у уха во время звонка (режим разговорного динамика).
class CallProximityController {
  CallProximityController._();

  static const _channel = MethodChannel('com.familychat/call_proximity');

  static bool _enabled = false;

  static Future<void> setEnabled(bool enabled) async {
    if (kIsWeb) return;
    SessionLog.instance.event('voice.callprox', enabled ? 'enable' : 'disable', {
      'wasEnabled': _enabled,
    });
    try {
      await _channel.invokeMethod<void>(enabled ? 'enable' : 'disable');
      _enabled = enabled;
    } catch (e) {
      SessionLog.instance.event('voice.callprox', 'fail', {'err': '$e'});
      debugPrint('call proximity failed: $e');
    }
  }

  static Future<void> disable() => setEnabled(false);
}
