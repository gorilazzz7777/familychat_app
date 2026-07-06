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
