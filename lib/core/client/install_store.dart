import 'package:flutter/foundation.dart';

import '../config/env.dart';
import '../updates/install_source.dart';
import 'app_client.dart';

/// Android install store for admin analytics: play | rustore | unknown.
///
/// Sent as [AppClient.installStoreHeaderName]. Backend accepts only these
/// three values (iOS / App Store → [unknown]).
class InstallStore {
  InstallStore._();

  static const String play = 'play';
  static const String rustore = 'rustore';
  static const String unknown = 'unknown';

  static String? _cached;

  static String? get current => _cached;

  static Future<String> resolve() async {
    if (_cached != null) return _cached!;

    final defined = _fromDefine(Env.storeTarget);
    if (defined != null) {
      _cached = defined;
      AppClient.setInstallStore(_cached!);
      if (kDebugMode) {
        debugPrint('[InstallStore] STORE=${Env.storeTarget} → $defined');
      }
      return _cached!;
    }

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      _cached = unknown;
      AppClient.setInstallStore(_cached!);
      return _cached!;
    }

    final installer = await InstallSource.installerPackageName();
    final normalized = _normalize(installer);
    _cached = normalized;
    AppClient.setInstallStore(normalized);
    if (kDebugMode) {
      debugPrint('[InstallStore] installer=$installer -> $normalized');
    }
    return normalized;
  }

  static String? _fromDefine(String raw) {
    switch (raw.trim().toLowerCase()) {
      case play:
      case 'google':
      case 'googleplay':
        return play;
      case rustore:
      case 'ru':
        return rustore;
      // Backend has no appstore value — treat as unknown for X-Install-Store.
      case 'appstore':
      case 'ios':
      case 'apple':
        return unknown;
      default:
        return null;
    }
  }

  static String _normalize(String? installer) {
    final raw = (installer ?? '').trim().toLowerCase();
    if (raw == InstallSource.playInstaller ||
        raw == 'com.google.android.feedback') {
      return play;
    }
    if (raw == InstallSource.rustoreInstaller) {
      return rustore;
    }
    if (raw == play || raw == rustore || raw == unknown) {
      return raw;
    }
    return unknown;
  }
}
