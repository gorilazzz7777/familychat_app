import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

/// OAuth на мобильных через ASWebAuthenticationSession / Chrome Custom Tabs,
/// чтобы callback `familychat://` закрывал браузер автоматически.
class OAuthLoginService {
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
    late final String resultUrl;
    try {
      resultUrl = await FlutterWebAuth2.authenticate(
        url: startUri.toString(),
        callbackUrlScheme: 'familychat',
        options: const FlutterWebAuth2Options(
          // Без ephemeral Google/VK могут требовать повторный логин каждый раз —
          // оставляем общий Safari-сессионный cookie-jar.
          preferEphemeral: false,
        ),
      );
    } on Exception catch (e) {
      final msg = '$e';
      if (msg.contains('CANCELED') ||
          msg.contains('canceled') ||
          msg.contains('cancelled')) {
        return {
          'status': 'canceled',
          'error': 'Вход отменён',
          'error_code': '',
        };
      }
      rethrow;
    }

    final uri = Uri.parse(resultUrl);
    if (uri.scheme != 'familychat' || uri.host != 'auth') {
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
