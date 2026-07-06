import 'package:flutter/foundation.dart';

abstract final class Env {
  static const String apiBaseUrl = String.fromEnvironment(
    'FAMILYCHAT_API_BASE_URL',
    defaultValue: 'https://remont-tracker.ru/api/v1/',
  );

  static const String webAppBaseUrl = String.fromEnvironment(
    'FAMILYCHAT_WEB_APP_URL',
    defaultValue: 'https://remont-tracker.ru/familychat/app',
  );

  static const String inviteBaseUrl = String.fromEnvironment(
    'FAMILYCHAT_INVITE_BASE_URL',
    defaultValue: 'https://remont-tracker.ru',
  );

  static const String rustoreAppUrl = String.fromEnvironment(
    'FAMILYCHAT_RUSTORE_APP_URL',
    defaultValue: '',
  );

  static Uri oauthStartUri(String provider, String nextUrl) {
    final base = apiBaseUrl.endsWith('/') ? apiBaseUrl : '$apiBaseUrl/';
    return Uri.parse('${base}auth/$provider/start/').replace(
      queryParameters: {'mode': 'login', 'next': nextUrl},
    );
  }

  static String authNextForProvider(String provider) {
    if (kIsWeb) {
      final base = webAppBaseUrl.replaceAll(RegExp(r'/+$'), '');
      return '$base/auth/$provider';
    }
    return switch (provider) {
      'yandex' => yandexAuthNext,
      'vk' => vkAuthNext,
      'google' => googleAuthNext,
      _ => yandexAuthNext,
    };
  }

  static const String yandexAuthNext = 'familychat://auth/yandex';
  static const String vkAuthNext = 'familychat://auth/vk';
  static const String googleAuthNext = 'familychat://auth/google';

  static Uri familychatWsUri(String accessToken) {
    final base = apiBaseUrl.replaceFirst(RegExp(r'/api/v1/?$'), '');
    final scheme = base.startsWith('https') ? 'wss' : 'ws';
    final host = Uri.parse(base).host;
    return Uri(
      scheme: scheme,
      host: host,
      path: '/api/v1/ws/familychat/',
      queryParameters: {'token': accessToken},
    );
  }
}
