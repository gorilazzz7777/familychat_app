import 'package:wakelock_plus/wakelock_plus.dart';

/// Общий wakelock: политика автоугасания + временные держатели (диафильм и т.п.).
abstract final class AppScreenKeepOn {
  static final Set<String> _holders = {};
  static bool _appPolicyOn = false;

  static Future<void> setAppPolicy(bool keepOn) async {
    _appPolicyOn = keepOn;
    await _sync();
  }

  static Future<void> acquire(String id) async {
    _holders.add(id);
    await _sync();
  }

  static Future<void> release(String id) async {
    _holders.remove(id);
    await _sync();
  }

  static Future<void> _sync() async {
    final on = _appPolicyOn || _holders.isNotEmpty;
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }
}
