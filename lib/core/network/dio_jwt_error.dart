import 'package:dio/dio.dart';

bool dioErrorIsExpiredJwtAccess(DioException err) {
  final status = err.response?.statusCode;
  if (status == 401) return true;
  if (status != 403) return false;
  final data = err.response?.data;
  if (data is! Map) return false;
  final map = Map<String, dynamic>.from(data);
  if (map['code']?.toString() != 'token_not_valid') return false;
  final messages = map['messages'];
  if (messages is! List || messages.isEmpty) return true;
  for (final m in messages) {
    if (m is! Map) continue;
    final mm = Map<String, dynamic>.from(m);
    final tokenType = mm['token_type']?.toString().toLowerCase();
    final tokenClass = mm['token_class']?.toString();
    if (tokenType == 'refresh' || tokenClass == 'RefreshToken') {
      return false;
    }
    if (tokenType == 'access' || tokenClass == 'AccessToken') {
      return true;
    }
  }
  return true;
}

bool _authorizationHeaderIsEmpty(RequestOptions options) {
  final raw = options.headers['Authorization'] ?? options.headers['authorization'];
  return raw == null || raw.toString().trim().isEmpty;
}

bool _detailLooksLikeMissingCredentials(Object? data) {
  if (data is! Map) return false;
  final map = Map<String, dynamic>.from(data);
  if (map['code']?.toString() == 'token_not_valid') return true;
  final detail = map['detail']?.toString().toLowerCase() ?? '';
  if (detail.isEmpty) return false;
  return detail.contains('учетные данные') ||
      detail.contains('учётные данные') ||
      detail.contains('credentials') ||
      detail.contains('not authenticated') ||
      detail.contains('authentication credentials');
}

const Object kAuthRestoreFailed = 'auth_restore_failed';

bool dioErrorIsAuthRestoreFailure(DioException err) {
  return identical(err.error, kAuthRestoreFailed) ||
      err.error == kAuthRestoreFailed;
}

/// 401/403, которые лечатся refresh или входом по device_id — не «нет прав».
bool dioErrorNeedsAuthRestore(DioException err) {
  final status = err.response?.statusCode;
  if (status == 401) return true;
  if (dioErrorIsExpiredJwtAccess(err)) return true;
  if (status != 403) return false;
  if (_authorizationHeaderIsEmpty(err.requestOptions)) return true;
  return _detailLooksLikeMissingCredentials(err.response?.data);
}
