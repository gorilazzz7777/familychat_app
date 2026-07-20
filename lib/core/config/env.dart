import 'package:flutter/foundation.dart';

abstract final class Env {
  static const String apiBaseUrl = String.fromEnvironment(
    'FAMILYCHAT_API_BASE_URL',
    defaultValue: 'https://familychat-app.ru/api/v1/',
  );

  static const String webAppBaseUrl = String.fromEnvironment(
    'FAMILYCHAT_WEB_APP_URL',
    defaultValue: 'https://familychat-app.ru/app',
  );

  static const String inviteBaseUrl = String.fromEnvironment(
    'FAMILYCHAT_INVITE_BASE_URL',
    defaultValue: 'https://familychat-app.ru',
  );

  static const String legalPrivacyUrl = String.fromEnvironment(
    'FAMILYCHAT_LEGAL_PRIVACY_URL',
    defaultValue: 'https://familychat-app.ru/legal/familychat/privacy-policy/',
  );

  static const String legalAgreementUrl = String.fromEnvironment(
    'FAMILYCHAT_LEGAL_AGREEMENT_URL',
    defaultValue: 'https://familychat-app.ru/legal/familychat/user-agreement/',
  );

  static const String rustoreAppUrl = String.fromEnvironment(
    'FAMILYCHAT_RUSTORE_APP_URL',
    defaultValue: '',
  );

  /// Базовый домен Yandex OAuth (ru — для пользователей из РФ).
  static const String yandexOAuthHost = String.fromEnvironment(
    'FAMILYCHAT_YANDEX_OAUTH_HOST',
    defaultValue: 'oauth.yandex.ru',
  );

  static Uri oauthStartUri(String provider, String nextUrl) {
    final base = apiBaseUrl.endsWith('/') ? apiBaseUrl : '$apiBaseUrl/';
    final params = <String, String>{
      'mode': 'login',
      'next': nextUrl,
    };
    if (provider == 'yandex') {
      params['authorize_host'] = yandexOAuthHost.contains('.ru') ? 'ru' : 'com';
    }
    return Uri.parse('${base}auth/$provider/start/').replace(
      queryParameters: params,
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
    final api = Uri.parse(
      apiBaseUrl.endsWith('/') ? apiBaseUrl : '$apiBaseUrl/',
    );
    final wsScheme = api.scheme == 'https' ? 'wss' : 'ws';
    final buffer = StringBuffer()
      ..write(wsScheme)
      ..write('://')
      ..write(api.host);
    final port = api.port;
    final includePort = port != 0 &&
        !((api.scheme == 'https' && port == 443) ||
            (api.scheme == 'http' && port == 80));
    if (includePort) {
      buffer.write(':$port');
    }
    buffer
      ..write('/api/v1/ws/familychat/?token=')
      ..write(Uri.encodeQueryComponent(accessToken));
    return Uri.parse(buffer.toString());
  }
}
