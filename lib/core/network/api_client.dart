import 'dart:async';

import 'package:dio/dio.dart';

import '../config/env.dart';
import '../session/auth_session_bus.dart';
import '../storage/token_storage.dart';
import 'dio_jwt_error.dart';

const String _kAuthRefreshPath = 'auth/refresh/';

bool _isAnonymousApiAuthPath(String path) {
  return path.contains(_kAuthRefreshPath) ||
      path.contains('auth/yandex/session/consume/') ||
      path.contains('auth/vk/session/consume/') ||
      path.contains('auth/google/session/consume/');
}

class ApiClient {
  ApiClient({TokenStorage? tokenStorage, Dio? dio})
      : tokenStorage = tokenStorage ?? TokenStorage(),
        dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: Env.apiBaseUrl,
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 90),
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                },
              ),
            ) {
    final client = this.dio;
    final storage = this.tokenStorage;
    client.interceptors.add(_AuthInterceptor(storage, client, client));
  }

  final TokenStorage tokenStorage;
  final Dio dio;
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._tokenStorage, this._refreshDio, this._retryDio);

  final TokenStorage _tokenStorage;
  final Dio _refreshDio;
  final Dio _retryDio;

  static const _kJwtRefreshRetried = '__jwt_refresh_retried';
  static Completer<String?>? _refreshCompleter;

  Future<void> _invalidateSession() async {
    await _tokenStorage.clear();
    AuthSessionBus.instance.emitSessionInvalidated();
  }

  Future<String?> _applyRefreshResponse(Map<String, dynamic>? data) async {
    if (data == null) return null;
    final access = data['access'] as String?;
    if (access == null || access.isEmpty) return null;
    final refresh = data['refresh'] as String?;
    if (refresh != null && refresh.isNotEmpty) {
      await _tokenStorage.saveTokens(access: access, refresh: refresh);
    } else {
      await _tokenStorage.saveAccess(access);
    }
    AuthSessionBus.instance.emitAccessRefreshed(access);
    return access;
  }

  Future<String?> _coordinatedRefresh(String refreshToken) async {
    final existing = _refreshCompleter;
    if (existing != null) {
      return existing.future;
    }
    final c = Completer<String?>();
    _refreshCompleter = c;
    try {
      final response = await _refreshDio.post<Map<String, dynamic>>(
        _kAuthRefreshPath,
        data: {'refresh': refreshToken},
      );
      final access = await _applyRefreshResponse(response.data);
      c.complete(access);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        c.completeError(e);
      } else {
        c.complete(null);
      }
    } catch (_) {
      c.complete(null);
    } finally {
      _refreshCompleter = null;
    }
    return c.future;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (!_isAnonymousApiAuthPath(options.path)) {
      final token = await _tokenStorage.readAccess();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
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

    final status = err.response?.statusCode;
    final request = err.requestOptions;
    final tryRefresh = (status == 401 || dioErrorIsExpiredJwtAccess(err)) &&
        request.extra[_kJwtRefreshRetried] != true;

    if (!tryRefresh) {
      return handler.next(err);
    }

    final refresh = await _tokenStorage.readRefresh();
    if (refresh == null || refresh.isEmpty) {
      await _invalidateSession();
      return handler.next(err);
    }

    try {
      final access = await _coordinatedRefresh(refresh);
      if (access == null || access.isEmpty) {
        return handler.next(err);
      }
      request.headers['Authorization'] = 'Bearer $access';
      request.extra[_kJwtRefreshRetried] = true;
      final response = await _retryDio.fetch<dynamic>(request);
      return handler.resolve(response);
    } on DioException catch (re) {
      final code = re.response?.statusCode;
      if (code == 401 || code == 403) {
        await _invalidateSession();
      }
      return handler.next(err);
    } catch (_) {
      return handler.next(err);
    }
  }
}
