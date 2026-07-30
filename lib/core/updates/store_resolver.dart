import 'package:flutter/foundation.dart';

import '../config/env.dart';
import 'app_distribution_store.dart';
import 'install_source.dart';

/// Resolves which store owns this build / install.
class StoreResolver {
  static AppDistributionStore? _cached;

  static Future<AppDistributionStore> resolve({bool forceRefresh = false}) async {
    if (!forceRefresh && _cached != null) return _cached!;
    final resolved = await _resolve();
    _cached = resolved;
    return resolved;
  }

  static Future<AppDistributionStore> _resolve() async {
    final defined = Env.storeTarget.trim().toLowerCase();
    switch (defined) {
      case 'play':
      case 'google':
      case 'googleplay':
        return AppDistributionStore.play;
      case 'rustore':
      case 'ru':
        return AppDistributionStore.rustore;
      case 'appstore':
      case 'ios':
      case 'apple':
        return AppDistributionStore.appstore;
    }

    if (kIsWeb) return AppDistributionStore.unknown;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppDistributionStore.appstore;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      return AppDistributionStore.unknown;
    }

    final installer = await InstallSource.installerPackageName();
    if (installer == InstallSource.playInstaller) {
      return AppDistributionStore.play;
    }
    if (installer == InstallSource.rustoreInstaller) {
      return AppDistributionStore.rustore;
    }
    return AppDistributionStore.unknown;
  }
}
