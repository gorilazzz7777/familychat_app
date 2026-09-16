import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android SSAID (`Settings.Secure.ANDROID_ID`) for server-side User glue.
///
/// iOS / web: always null — do not invent stubs that look like real ids.
abstract final class AndroidSsaid {
  static const _channel = MethodChannel('com.familychat/ssaid');
  static const _minLen = 8;

  static String? _cached;
  static bool _resolved = false;

  /// Cached ANDROID_ID, or null if unavailable / not Android.
  static Future<String?> read() async {
    if (_resolved) return _cached;
    _resolved = true;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      _cached = null;
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<String>('getAndroidId');
      final value = (raw ?? '').trim();
      if (value.length < _minLen) {
        _cached = null;
        return null;
      }
      _cached = value;
      return _cached;
    } catch (e) {
      debugPrint('[AndroidSsaid] read failed: $e');
      _cached = null;
      return null;
    }
  }

  /// Fields for auth payloads (`ssaid` + `ssaid_platform`), empty on non-Android.
  static Future<Map<String, String>> authFields() async {
    final id = await read();
    if (id == null || id.isEmpty) return const {};
    return {
      'ssaid': id,
      'ssaid_platform': 'android',
    };
  }
}
