import 'package:dio/dio.dart';

/// Проверка доступности API без отдельного пакета connectivity.
abstract final class ChatNetworkStatus {
  static bool looksOffline(Object? error) {
    if (error is! DioException) return false;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        (error.type == DioExceptionType.unknown && error.error != null);
  }

  /// Transient failures worth retrying. 4xx (except 429) fail immediately.
  static bool isRetryable(Object? error) {
    if (looksOffline(error)) return true;
    if (error is! DioException) return true;
    final code = error.response?.statusCode;
    if (code == null) return true;
    if (code == 429) return true;
    if (code >= 500) return true;
    return false;
  }

  static Future<bool> isOnline(Future<void> Function() ping) async {
    try {
      await ping();
      return true;
    } catch (error) {
      if (looksOffline(error)) return false;
      return true;
    }
  }
}
