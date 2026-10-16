import 'package:flutter/foundation.dart';

import '../network/api_origin.dart';

abstract final class Env {
  /// Optional full override (`…/api/v1/`). When set, [ApiOrigin] locks to it.
  static const String compileApiBaseUrl = String.fromEnvironment(
    'FAMILYCHAT_API_BASE_URL',
    defaultValue: '',
  );

  static const String _compileWebApp = String.fromEnvironment(
    'FAMILYCHAT_WEB_APP_URL',
    defaultValue: '',
  );

  static const String _compileInvite = String.fromEnvironment(
    'FAMILYCHAT_INVITE_BASE_URL',
    defaultValue: '',
  );

  static const String _compileLegalPrivacy = String.fromEnvironment(
    'FAMILYCHAT_LEGAL_PRIVACY_URL',
    defaultValue: '',
  );

  static const String _compileLegalAgreement = String.fromEnvironment(
    'FAMILYCHAT_LEGAL_AGREEMENT_URL',
    defaultValue: '',
  );

  static const String _compileLegalChildSafety = String.fromEnvironment(
    'FAMILYCHAT_LEGAL_CHILD_SAFETY_URL',
    defaultValue: '',
  );

  /// Live origin after MegaFon port race (`:443` ↔ `:4443`).
  static String get origin => ApiOrigin.current;

  static String get apiBaseUrl {
    if (compileApiBaseUrl.isNotEmpty) {
      return compileApiBaseUrl.endsWith('/')
          ? compileApiBaseUrl
          : '$compileApiBaseUrl/';
    }
    return '${ApiOrigin.current}/api/v1/';
  }

  static String get webAppBaseUrl {
    if (_compileWebApp.isNotEmpty) return _compileWebApp;
    return '${ApiOrigin.current}/app';
  }

  static String get inviteBaseUrl {
    if (_compileInvite.isNotEmpty) return _compileInvite;
    return ApiOrigin.current;
  }

  static String get legalPrivacyUrl => _compileLegalPrivacy.isNotEmpty
      ? _compileLegalPrivacy
      : '${ApiOrigin.current}/legal/familychat/privacy-policy/';

  static String get legalAgreementUrl => _compileLegalAgreement.isNotEmpty
      ? _compileLegalAgreement
      : '${ApiOrigin.current}/legal/familychat/user-agreement/';

  static String get legalChildSafetyUrl => _compileLegalChildSafety.isNotEmpty
      ? _compileLegalChildSafety
      : '${ApiOrigin.current}/legal/familychat/child-safety-standards/';

  static const String rustoreAppUrl = String.fromEnvironment(
    'FAMILYCHAT_RUSTORE_APP_URL',
    defaultValue:
        'https://www.rustore.ru/catalog/app/com.familychat.familychat_app',
  );

  /// Канал дистрибуции при сборке: auto | play | rustore | appstore.
  static const String storeTarget = String.fromEnvironment(
    'STORE',
    defaultValue: 'auto',
  );

  static const String playStoreAppUrl = String.fromEnvironment(
    'FAMILYCHAT_PLAY_STORE_URL',
    defaultValue:
        'https://play.google.com/store/apps/details?id=com.familychat.familychat_app',
  );

  static const String appStoreAppUrl = String.fromEnvironment(
    'FAMILYCHAT_APP_STORE_URL',
    defaultValue: 'https://apps.apple.com/app/id000000000',
  );

  /// Базовый домен Yandex OAuth (ru — для пользователей из РФ).
  static const String yandexOAuthHost = String.fromEnvironment(
    'FAMILYCHAT_YANDEX_OAUTH_HOST',
    defaultValue: 'oauth.yandex.ru',
  );

  static Uri oauthStartUri(
    String provider,
    String nextUrl, {
    String? deviceId,
  }) {
    final base = apiBaseUrl.endsWith('/') ? apiBaseUrl : '$apiBaseUrl/';
    final params = <String, String>{
      'mode': 'login',
      'next': nextUrl,
    };
    if (provider == 'yandex') {
      params['authorize_host'] = yandexOAuthHost.contains('.ru') ? 'ru' : 'com';
    }
    final id = (deviceId ?? '').trim();
    if (id.isNotEmpty) {
      params['device_id'] = id;
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
