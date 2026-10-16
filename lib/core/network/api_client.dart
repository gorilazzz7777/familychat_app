import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/env.dart';
import '../client/app_client.dart';
import '../storage/token_storage.dart';
import 'api_origin.dart';
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

bool _isTransportFailure(DioException err) {
  switch (err.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return true;
    case DioExceptionType.unknown:
      return isLikelyCronetTransportFailure(err.error) ||
          isLikelyCronetTransportFailure(err.message);
    default:
      return false;
  }
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
    _refreshDio = _newDio();
    configureNativeHttpAdapter(_refreshDio);
    configureNativeHttpAdapter(this.dio);
    authRefresher = AuthTokenRefresher(
      tokenStorage: storage,
      refreshDio: _refreshDio,
    );

    _applyOrigin(ApiOrigin.current);
    ApiOrigin.addListener(_onOriginChanged);

    void wire(Dio d) {
      d.interceptors.add(_OriginFailoverInterceptor(this));
      d.interceptors.add(_AuthInterceptor(authRefresher, d));
    }

    wire(this.dio);
    if (!identical(this.dio, this.sendDio)) {
      configureNativeHttpAdapter(this.sendDio);
      wire(this.sendDio);
    }
    // Refresh dio: origin failover only (no auth retry loop).
    _refreshDio.interceptors.add(_OriginFailoverInterceptor(this));

    if (kDebugMode) {
      debugPrint(
        '[ApiClient] origin=${ApiOrigin.current} '
        'adapter=${this.dio.httpClientAdapter.runtimeType} '
        'sendAdapter=${this.sendDio.httpClientAdapter.runtimeType} '
        'shared=${identical(this.dio, this.sendDio)}',
      );
    }
  }

  final TokenStorage tokenStorage;
  final Dio dio;

  /// Dedicated connection pool for chat send / outbox mutations.
  final Dio sendDio;
  late final Dio _refreshDio;

  late final AuthTokenRefresher authRefresher;

  void _onOriginChanged(String origin) => _applyOrigin(origin);

  void _applyOrigin(String origin) {
    final base = Env.apiBaseUrl;
    dio.options.baseUrl = base;
    sendDio.options.baseUrl = base;
    _refreshDio.options.baseUrl = base;
    if (kDebugMode) {
      debugPrint('[ApiClient] baseUrl=$base (origin=$origin)');
    }
  }

  /// Превентивный refresh (таймер / возврат в приложение / перед пачкой запросов).
  Future<String?> ensureFreshAccess() => authRefresher.ensureAccess();

  /// Cronet transport failures → dart:io for this process.
  void forceDartIoTransport() {
    forceDartIoHttpAdapters([dio, sendDio, _refreshDio]);
  }
}

class _OriginFailoverInterceptor extends Interceptor {
  _OriginFailoverInterceptor(this._client);

  final ApiClient _client;
  static const _kOriginRetried = '__api_origin_retried';

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      await ApiOrigin.ensureReady().timeout(const Duration(seconds: 4));
    } catch (_) {}
    options.baseUrl = Env.apiBaseUrl;
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final request = err.requestOptions;
    if (request.extra[_kOriginRetried] == true || !_isTransportFailure(err)) {
      return handler.next(err);
    }
    final failedOrigin = Uri.tryParse(request.baseUrl)?.origin ??
        ApiOrigin.current;
    final switched = await ApiOrigin.failoverFrom(failedOrigin);
    if (!switched) {
      return handler.next(err);
    }
    _client._applyOrigin(ApiOrigin.current);
    request.baseUrl = Env.apiBaseUrl;
    request.extra[_kOriginRetried] = true;
    try {
      final response = await _client.dio.fetch<dynamic>(request);
      return handler.resolve(response);
    } on DioException catch (retryErr) {
      return handler.next(retryErr);
    } catch (_) {
      return handler.next(err);
    }
  }
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._refresher, this._retryDio);

  final AuthTokenRefresher _refresher;
  final Dio _retryDio;

  static const _kAuthRestoreRetried = '__auth_restore_retried';

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    // Keep X-Client-App / X-Install-Store current (store may resolve after Dio init).
    options.headers.addAll(AppClient.extraHeaders);
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
