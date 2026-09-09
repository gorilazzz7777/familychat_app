import 'dart:convert';

/// Refresh this far before JWT `exp`, so a burst of API calls never hits 401/403.
const Duration kJwtProactiveRefreshLeeway = Duration(seconds: 90);

/// Cap a single timer tick; we re-check and arm again if the token still has time.
const Duration kJwtProactiveRefreshMaxWait = Duration(minutes: 10);

/// If `exp` is missing, still refresh periodically instead of waiting for 401/403.
const Duration kJwtProactiveRefreshFallback = Duration(minutes: 4);

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
  DateTime? now,
}) {
  final exp = jwtAccessTokenExpiry(token);
  if (exp == null) return false;
  final n = (now ?? DateTime.now()).toUtc();
  return n.add(leeway).isAfter(exp);
}

/// True when we should refresh before sending the next request.
bool jwtAccessTokenNeedsProactiveRefresh(
  String token, {
  Duration leeway = kJwtProactiveRefreshLeeway,
  DateTime? now,
}) {
  return jwtAccessTokenIsExpired(token, leeway: leeway, now: now);
}

/// Delay until the next proactive refresh. [Duration.zero] means refresh now.
Duration jwtAccessTokenProactiveWait(
  String token, {
  Duration leeway = kJwtProactiveRefreshLeeway,
  Duration maxWait = kJwtProactiveRefreshMaxWait,
  Duration fallback = kJwtProactiveRefreshFallback,
  DateTime? now,
}) {
  final exp = jwtAccessTokenExpiry(token);
  if (exp == null) return fallback;
  final n = (now ?? DateTime.now()).toUtc();
  var delay = exp.subtract(leeway).difference(n);
  if (delay.isNegative) return Duration.zero;
  if (delay > maxWait) return maxWait;
  return delay;
}
