import 'package:dio/dio.dart';

import '../../../core/config/env.dart';
import '../../../core/network/api_client.dart';

class AuthRepository {
  AuthRepository(this._client);

  final ApiClient _client;

  Future<bool> hasSession() => _client.tokenStorage.hasRefreshCredential();

  Future<void> consumeSession({
    required String provider,
    required String sessionCode,
  }) async {
    final path = switch (provider) {
      'yandex' => 'auth/yandex/session/consume/',
      'vk' => 'auth/vk/session/consume/',
      'google' => 'auth/google/session/consume/',
      _ => throw ArgumentError('provider'),
    };
    final res = await _client.dio.post<Map<String, dynamic>>(
      path,
      data: {'session_code': sessionCode},
    );
    final data = res.data!;
    await _client.tokenStorage.saveTokens(
      access: data['access'] as String,
      refresh: data['refresh'] as String,
    );
  }

  Uri oauthStartUri(String provider) {
    return Env.oauthStartUri(provider, Env.authNextForProvider(provider));
  }

  Future<void> logout() async {
    try {
      await _client.dio.post<void>(
        'auth/logout/',
        options: Options(
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
    } catch (_) {
      // Сеть или просроченный токен — всё равно очищаем сессию локально.
    }
    await _client.tokenStorage.clear();
  }

  Future<void> deleteAccount({required bool confirmDeletion}) async {
    await _client.dio.delete<void>(
      'auth/me/',
      data: {'confirm_deletion': confirmDeletion},
      options: Options(
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
  }
}
