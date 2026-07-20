import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/platform/app_foreground.dart';
import '../../../core/routing/app_uri_parser.dart';

/// OAuth на мобильных через ASWebAuthenticationSession / Chrome Custom Tabs,
/// чтобы callback `familychat://` закрывал браузер автоматически.
class OAuthLoginService {
  static const _callbackScheme = 'familychat';

  /// Пока идёт вход с LoginScreen — bootstrap не должен забирать session_code.
  static String? activeProvider;

  static bool get isFlowActive => activeProvider != null;

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
    final appLinks = AppLinks();
    StreamSubscription<Uri>? linkSub;
    final linkCompleter = Completer<String>();

    void onAuthUri(Uri uri) {
      if (linkCompleter.isCompleted) return;
      final parsed = parseOAuthCallback(uri);
      if (parsed == null || parsed.provider != provider) return;
      linkCompleter.complete(uri.toString());
    }

    activeProvider = provider;
    linkSub = appLinks.uriLinkStream.listen(onAuthUri);

    try {
      late final String resultUrl;
      try {
        resultUrl = await Future.any<String>([
          FlutterWebAuth2.authenticate(
            url: startUri.toString(),
            callbackUrlScheme: _callbackScheme,
            options: const FlutterWebAuth2Options(
              // NO_HISTORY — Custom Tab закрывается после deep link callback.
              intentFlags: ephemeralIntentFlags,
            ),
          ),
          linkCompleter.future,
        ]);
      } on Exception catch (e) {
        if (!_isUserCanceled(e)) rethrow;
        try {
          resultUrl = await linkCompleter.future.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          return const {
            'status': 'canceled',
            'error': 'Вход отменён',
            'error_code': '',
          };
        }
      }

      await bringAppToForeground();
      return _parseResultUrl(resultUrl, provider);
    } finally {
      activeProvider = null;
      await linkSub.cancel();
    }
  }

  bool _isUserCanceled(Object e) {
    final msg = '$e';
    return msg.contains('CANCELED') ||
        msg.contains('canceled') ||
        msg.contains('cancelled');
  }

  Map<String, String> _parseResultUrl(String resultUrl, String provider) {
    final uri = Uri.parse(resultUrl);
    if (uri.scheme != _callbackScheme || uri.host != 'auth') {
      throw StateError('Неожиданный ответ входа');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty || segments.first != provider) {
      throw StateError('Неожиданный провайдер входа');
    }

    final status = uri.queryParameters['status'];
    if (status != null && status != 'ok') {
      return {
        'status': status,
        'error': uri.queryParameters['error_description'] ?? status,
        'error_code': uri.queryParameters['error_code'] ?? '',
      };
    }

    final code = uri.queryParameters['session_code'];
    if (code == null || code.isEmpty) {
      throw StateError('Сервер не вернул код сессии');
    }

    return {
      'status': 'ok',
      'session_code': code.replaceAll(RegExp(r'\\+$'), ''),
    };
  }
}
