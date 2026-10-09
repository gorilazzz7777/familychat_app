import 'package:dio/dio.dart';

import 'services_access.dart';

/// Registers this device's public IP on the Services proxy allowlist.
///
/// Must hit the register host **directly** (not via familychat-app.ru), because
/// the :443 stream mux makes Django see 127.0.0.1 instead of the phone IP.
class ServicesProxyRegistrar {
  ServicesProxyRegistrar();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  Future<void> register(ServicesRegisterConfig config) async {
    if (config.url.isEmpty || config.token.isEmpty) {
      throw StateError('register_not_configured');
    }
    final res = await _dio.get<Map<String, dynamic>>(
      config.url,
      queryParameters: {'token': config.token},
    );
    final data = res.data ?? const <String, dynamic>{};
    if (res.statusCode != 200 || data['status']?.toString() != 'ready') {
      throw StateError(data['error']?.toString() ?? 'register_failed');
    }
  }
}
