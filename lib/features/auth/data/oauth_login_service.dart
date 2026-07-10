import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

class OAuthLoginService {
  OAuthLoginService({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;

  Future<Map<String, String>> run({
    required String provider,
    required Uri startUri,
  }) async {
    if (kIsWeb) {
      final launched = await launchUrl(startUri, webOnlyWindowName: '_self');
      if (!launched) {
        throw StateError('Не удалось открыть страницу входа');
      }
      await Completer<void>().future;
    }
    return _runMobile(provider: provider, startUri: startUri);
  }

  Future<Map<String, String>> _runMobile({
    required String provider,
    required Uri startUri,
  }) async {
    final completer = Completer<Map<String, String>>();
    StreamSubscription<Uri>? sub;

    bool handleUri(Uri uri) {
      if (uri.scheme != 'familychat' || uri.host != 'auth') return false;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty || segments.first != provider) return false;

      final status = uri.queryParameters['status'];
      if (status != null && status != 'ok') {
        if (!completer.isCompleted) {
          completer.complete({
            'status': status,
            'error': uri.queryParameters['error_description'] ?? status,
            'error_code': uri.queryParameters['error_code'] ?? '',
          });
        }
        return true;
      }
      final code = uri.queryParameters['session_code'];
      if (code != null && code.isNotEmpty) {
        if (!completer.isCompleted) {
          completer.complete({
            'status': 'ok',
            'session_code': code.replaceAll(RegExp(r'\\+$'), ''),
          });
        }
        return true;
      }
      return false;
    }

    sub = _appLinks.uriLinkStream.listen((uri) {
      if (handleUri(uri)) sub?.cancel();
    });

    final launched = await launchUrl(startUri, mode: LaunchMode.inAppBrowserView);
    if (!launched) {
      final external = await launchUrl(startUri, mode: LaunchMode.externalApplication);
      if (!external) {
        await sub.cancel();
        throw StateError('Не удалось открыть браузер для входа.');
      }
    }

    try {
      return await completer.future.timeout(
        const Duration(minutes: 8),
        onTimeout: () => throw TimeoutException('Вход не завершён'),
      );
    } finally {
      await sub.cancel();
    }
  }
}
