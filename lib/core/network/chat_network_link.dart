import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

enum ChatNetworkLinkKind {
  wifi,
  mobile,
  offline,
  unknown,
}

abstract final class ChatNetworkLink {
  static final Connectivity _connectivity = Connectivity();

  static ChatNetworkLinkKind mapResults(List<ConnectivityResult> results) {
    if (kIsWeb) return ChatNetworkLinkKind.wifi;
    if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
      return ChatNetworkLinkKind.offline;
    }
    if (results.any(
      (r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn,
    )) {
      return ChatNetworkLinkKind.wifi;
    }
    if (results.any((r) => r == ConnectivityResult.mobile)) {
      return ChatNetworkLinkKind.mobile;
    }
    return ChatNetworkLinkKind.unknown;
  }

  static Future<ChatNetworkLinkKind> current() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return mapResults(results);
    } catch (_) {
      return ChatNetworkLinkKind.unknown;
    }
  }

  static Stream<ChatNetworkLinkKind> watch() async* {
    yield await current();
    yield* _connectivity.onConnectivityChanged.map(mapResults);
  }
}
