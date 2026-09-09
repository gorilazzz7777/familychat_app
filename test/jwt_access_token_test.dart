import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:familychat_app/core/network/jwt_access_token.dart';

String _jwt({required int exp}) {
  final payload = base64Url.encode(utf8.encode(jsonEncode({'exp': exp})));
  return 'header.$payload.sig';
}

void main() {
  const expired =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEwMDAwMDAwMDB9.sig';
  const valid =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjQwMDAwMDAwMDB9.sig';

  test('jwtAccessTokenIsExpired detects expired access token', () {
    expect(jwtAccessTokenIsExpired(expired), isTrue);
    expect(jwtAccessTokenIsExpired(valid), isFalse);
  });

  test('proactive refresh triggers inside 90s leeway, not after 403', () {
    final now = DateTime.utc(2026, 9, 10, 0, 0, 0);
    final exp = now.add(const Duration(seconds: 60)).millisecondsSinceEpoch ~/ 1000;
    final token = _jwt(exp: exp);
    expect(jwtAccessTokenNeedsProactiveRefresh(token, now: now), isTrue);
    expect(jwtAccessTokenProactiveWait(token, now: now), Duration.zero);
  });

  test('proactive wait is exp minus leeway and capped', () {
    final now = DateTime.utc(2026, 9, 10, 0, 0, 0);
    final expSoon =
        now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
    final tokenSoon = _jwt(exp: expSoon);
    expect(
      jwtAccessTokenProactiveWait(tokenSoon, now: now),
      const Duration(minutes: 5) - kJwtProactiveRefreshLeeway,
    );

    final expFar =
        now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000;
    final tokenFar = _jwt(exp: expFar);
    expect(
      jwtAccessTokenProactiveWait(tokenFar, now: now),
      kJwtProactiveRefreshMaxWait,
    );
  });

  test('token without exp uses fallback interval', () {
    expect(
      jwtAccessTokenProactiveWait('not-a-jwt'),
      kJwtProactiveRefreshFallback,
    );
    expect(jwtAccessTokenNeedsProactiveRefresh('not-a-jwt'), isFalse);
  });
}
