import 'package:dio/dio.dart';

import '../../../core/config/env.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/device_id_storage.dart';
import '../../../core/storage/guest_session_storage.dart';

class AuthRepository {
  AuthRepository(this._client);

  final ApiClient _client;

  Future<bool> hasSession() => _client.tokenStorage.hasRefreshCredential();

  Future<void> _saveAuthTokens(Map<String, dynamic> data) async {
    await _client.tokenStorage.saveTokens(
      access: data['access'] as String,
      refresh: data['refresh'] as String,
    );
  }

  Future<void> guestLogin() async {
    final deviceId = await DeviceIdStorage.getOrCreate();
    final res = await _client.dio.post<Map<String, dynamic>>(
      'auth/guest/',
      data: {'device_id': deviceId},
    );
    await _saveAuthTokens(res.data!);
    await GuestSessionStorage.markActive();
  }

  Future<bool> tryDeviceAuth() async {
    final existing = await DeviceIdStorage.peek();
    if (existing == null) return false;
    try {
      final res = await _client.dio.post<Map<String, dynamic>>(
        'auth/device-auth/',
        data: {'device_id': existing},
      );
      await _saveAuthTokens(res.data!);
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) return false;
      rethrow;
    }
  }

  /// Восстановить сессию: refresh, иначе device-auth, иначе новый guest.
  Future<bool> ensureSession() async {
    if (await hasSession()) return true;
    if (await tryDeviceAuth()) {
      await syncGuestSessionFlag();
      return true;
    }
    await guestLogin();
    return true;
  }

  Future<void> ensureDeviceBound() async {
    final deviceId = await DeviceIdStorage.getOrCreate();
    try {
      await _client.dio.post<void>(
        'auth/ensure-device/',
        data: {'device_id': deviceId},
        options: Options(
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> fetchMe() async {
    try {
      final res = await _client.dio.get<Map<String, dynamic>>('auth/me/');
      return res.data;
    } on DioException {
      return null;
    }
  }

  Future<bool> syncGuestSessionFlag() async {
    try {
      final me = await fetchMe();
      final user = me?['user'];
      if (user is Map && _isGuestValue(user['is_guest'])) {
        await GuestSessionStorage.markActive();
        return true;
      }
      if (user is Map && user['is_guest'] == false) {
        await GuestSessionStorage.clear();
      }
    } catch (_) {}
    return GuestSessionStorage.isActiveGuestSession();
  }

  static bool _isGuestValue(dynamic value) {
    return value == true ||
        value == 1 ||
        value?.toString().toLowerCase() == 'true';
  }

  Future<void> exchangeImpersonation(String code) async {
    final res = await _client.dio.post<Map<String, dynamic>>(
      'auth/impersonation/exchange/',
      data: {'code': code},
    );
    await _saveAuthTokens(res.data!);
  }

  Future<void> consumeSession({
    required String provider,
    required String sessionCode,
  }) async {
    final deviceId = await DeviceIdStorage.getOrCreate();
    final path = switch (provider) {
      'yandex' => 'auth/yandex/session/consume/',
      'vk' => 'auth/vk/session/consume/',
      'google' => 'auth/google/session/consume/',
      _ => throw ArgumentError('provider'),
    };
    final res = await _client.dio.post<Map<String, dynamic>>(
      path,
      data: {
        'session_code': sessionCode,
        'device_id': deviceId,
      },
    );
    await _saveAuthTokens(res.data!);
    await GuestSessionStorage.clear();
  }

  Future<Uri> oauthStartUri(String provider) async {
    final deviceId = await DeviceIdStorage.getOrCreate();
    return Env.oauthStartUri(
      provider,
      Env.authNextForProvider(provider),
      deviceId: deviceId,
    );
  }

  /// Гостю — только локальный выход (device-auth восстановит сессию).
  /// Явный выход из соцсети — серверный logout и новый device_id.
  /// Протухшие токены ([explicit] = false) — device_id сохраняем для автовхода.
  Future<void> logout({bool isGuest = false, bool explicit = true}) async {
    if (explicit && !isGuest) {
      await GuestSessionStorage.clear();
      try {
        await _client.dio.post<void>(
          'auth/logout/',
          options: Options(
            validateStatus: (status) =>
                status != null && status >= 200 && status < 300,
          ),
        );
      } catch (_) {}
      await DeviceIdStorage.regenerate();
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
    await GuestSessionStorage.clear();
    await DeviceIdStorage.regenerate();
  }
}
