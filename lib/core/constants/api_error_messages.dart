import 'package:dio/dio.dart';

import '../network/dio_jwt_error.dart';

String userFacingErrorMessage(Object error) {
  if (error is DioException) {
    if (dioErrorIsAuthRestoreFailure(error) ||
        dioErrorNeedsAuthRestore(error)) {
      return 'Нужно войти заново.';
    }
    final code = error.response?.statusCode;
    final detail = _apiDetail(error.response?.data);
    if (detail != null && !_isBoilerplateApiDetail(detail)) {
      return detail;
    }
    if (code == 403) {
      return 'Нет доступа.';
    }
    if (code == 401) {
      return 'Нужно войти заново.';
    }
    if (code == 500) {
      return 'Сервер временно недоступен. Попробуйте позже.';
    }
    if (code != null) {
      return 'Ошибка сервера ($code).';
    }
    return 'Нет связи с сервером.';
  }
  return error.toString();
}

String? _apiDetail(Object? data) {
  if (data is! Map) return null;
  final raw = data['detail'];
  if (raw == null) return null;
  final text = raw.toString().trim();
  return text.isEmpty ? null : text;
}

bool _isBoilerplateApiDetail(String detail) {
  final lower = detail.toLowerCase();
  return lower.contains('you do not have permission') ||
      lower.contains('authentication credentials') ||
      lower.contains('учетные данные') ||
      lower.contains('учётные данные') ||
      lower.contains('token_not_valid') ||
      detail.length > 180;
}
