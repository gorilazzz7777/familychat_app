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
