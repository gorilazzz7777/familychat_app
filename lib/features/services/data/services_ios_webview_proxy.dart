import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'services_access.dart';

/// iOS 17+ WKWebsiteDataStore HTTP CONNECT proxy for Services WebView.
///
/// Android uses [ProxyController] / WebView PROXY_OVERRIDE instead.
class ServicesIosWebViewProxy {
  ServicesIosWebViewProxy._();

  static const _channel = MethodChannel('com.familychat/services_webview_proxy');

  static Future<bool> isSupported() async {
    if (!Platform.isIOS) return false;
    try {
      final v = await _channel.invokeMethod<bool>('isSupported');
      return v == true;
    } catch (e) {
      debugPrint('[services_ios_proxy] isSupported fail $e');
      return false;
    }
  }

  static Future<void> setProxy(ServicesProxyConfig proxy) async {
    if (proxy.host.isEmpty || proxy.port <= 0) {
      throw StateError('invalid_proxy');
    }
    await _channel.invokeMethod<void>('setProxy', {
      'host': proxy.host,
      'port': proxy.port,
      'scheme': proxy.scheme,
    });
  }

  static Future<void> clearProxy() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('clearProxy');
    } catch (e) {
      debugPrint('[services_ios_proxy] clearProxy fail $e');
    }
  }
}
