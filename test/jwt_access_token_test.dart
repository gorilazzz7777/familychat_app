import 'package:flutter_test/flutter_test.dart';
import 'package:familychat_app/core/network/jwt_access_token.dart';

void main() {
  const expired =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEwMDAwMDAwMDB9.sig';
  const valid =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjQwMDAwMDAwMDB9.sig';

  test('jwtAccessTokenIsExpired detects expired access token', () {
    expect(jwtAccessTokenIsExpired(expired), isTrue);
    expect(jwtAccessTokenIsExpired(valid), isFalse);
  });
}
