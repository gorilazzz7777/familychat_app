import 'dart:convert';

/// Reads JWT `exp` (UTC). Returns null if the token is not a decodable JWT.
DateTime? jwtAccessTokenExpiry(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final normalized = base64Url.normalize(parts[1]);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final map = jsonDecode(decoded);
    if (map is! Map) return null;
    final exp = map['exp'];
    if (exp is int) {
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    }
    if (exp is num) {
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
    }
  } catch (_) {}
  return null;
}

/// True when the access token is expired or will expire within [leeway].
bool jwtAccessTokenIsExpired(
  String token, {
  Duration leeway = const Duration(seconds: 30),
}) {
  final exp = jwtAccessTokenExpiry(token);
  if (exp == null) return false;
  return DateTime.now().toUtc().add(leeway).isAfter(exp);
}
