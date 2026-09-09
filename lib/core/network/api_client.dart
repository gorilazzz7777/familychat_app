import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/env.dart';
import '../client/app_client.dart';
import '../storage/token_storage.dart';
import 'auth_token_refresher.dart';
import 'dio_jwt_error.dart';
import 'native_http_adapter.dart';

bool _isAnonymousApiAuthPath(String path) {
  return path.contains(kAuthRefreshPath) ||
      path.contains('auth/guest/') ||
      path.contains(kAuthDeviceAuthPath) ||
      path.contains('auth/yandex/session/consume/') ||
      path.contains('auth/vk/session/consume/') ||
      path.contains('auth/google/session/consume/');
}

BaseOptions _apiBaseOptions() {
  return BaseOptions(
    baseUrl: Env.apiBaseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 90),
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      ...AppClient.extraHeaders,
    },
  );
}

Dio _newDio() => Dio(_apiBaseOptions());

class ApiClient {
  /// [dio] — общий клиент (sync/prefetch/UI).
  /// [sendDio] — отдельный пул для исходящих сообщений outbox, чтобы тяжёлый
  /// трафик на [dio] не ставил POST send в очередь.
  ///
  /// Если передан только [dio] (тесты) — [sendDio] совпадает с ним.
  ApiClient({TokenStorage? tokenStorage, Dio? dio, Dio? sendDio})
      : tokenStorage = tokenStorage ?? TokenStorage(),
        dio = dio ?? _newDio(),
        sendDio = sendDio ?? dio ?? _newDio() {
    final storage = this.tokenStorage;
    final refreshDio = _newDio();
    configureNativeHttpAdapter(refreshDio);
    configureNativeHttpAdapter(this.dio);
    authRefresher = AuthTokenRefresher(
      tokenStorage: storage,
      refreshDio: refreshDio,
    );
    this.dio.interceptors.add(
          _AuthInterceptor(authRefresher, this.dio),
        );

    if (!identical(this.dio, this.sendDio)) {
      configureNativeHttpAdapter(this.sendDio);
      this.sendDio.interceptors.add(
            _AuthInterceptor(authRefresher, this.sendDio),
          );
    }

    if (kDebugMode) {
      debugPrint(
        '[ApiClient] http adapter=${this.dio.httpClientAdapter.runtimeType} '
        'sendAdapter=${this.sendDio.httpClientAdapter.runtimeType} '
        'shared=${identical(this.dio, this.sendDio)}',
      );
    }
  }

  final TokenStorage tokenStorage;
  final Dio dio;

  /// Dedicated connection pool for chat send / outbox mutations.
  final Dio sendDio;

  late final AuthTokenRefresher authRefresher;

  /// Превентивный refresh (таймер / возврат в приложение / перед пачкой запросов).
  Future<String?> ensureFreshAccess() => authRefresher.ensureAccess();
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._refresher, this._retryDio);

  final AuthTokenRefresher _refresher;
  final Dio _retryDio;

  static const _kAuthRestoreRetried = '__auth_restore_retried';

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    if (!_isAnonymousApiAuthPath(options.path)) {
      final token = await _refresher.ensureAccess();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      } else {
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            error: kAuthRestoreFailed,
            message: 'Нужно войти заново.',
          ),
        );
      }
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final path = err.requestOptions.path;
    if (_isAnonymousApiAuthPath(path)) {
      return handler.next(err);
    }

    final request = err.requestOptions;
    final alreadyTried = request.extra[_kAuthRestoreRetried] == true;
    if (alreadyTried || !dioErrorNeedsAuthRestore(err)) {
      return handler.next(err);
    }

    final access = await _refresher.ensureAccess(force: true);
    if (access == null || access.isEmpty) {
      return handler.next(
        DioException(
          requestOptions: request,
          type: DioExceptionType.unknown,
          error: kAuthRestoreFailed,
          message: 'Нужно войти заново.',
        ),
      );
    }

    request.headers['Authorization'] = 'Bearer $access';
    request.extra[_kAuthRestoreRetried] = true;
    try {
      final response = await _retryDio.fetch<dynamic>(request);
      return handler.resolve(response);
    } on DioException catch (retryErr) {
      if (dioErrorNeedsAuthRestore(retryErr)) {
        return handler.next(
          DioException(
            requestOptions: request,
            type: DioExceptionType.unknown,
            error: kAuthRestoreFailed,
            message: 'Нужно войти заново.',
          ),
        );
      }
      return handler.next(retryErr);
    } catch (_) {
      return handler.next(err);
    }
  }
}
