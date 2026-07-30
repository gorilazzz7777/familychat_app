import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Installer package name for the current Android install (null if unknown).
class InstallSource {
  static const MethodChannel _channel =
      MethodChannel('com.familychat.familychat_app/install_source');

  static const playInstaller = 'com.android.vending';
  static const rustoreInstaller = 'ru.vk.store';

  static Future<String?> installerPackageName() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<String>('getInstallerPackageName');
      final value = raw?.trim();
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }
}