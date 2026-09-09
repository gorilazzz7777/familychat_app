import 'package:dio/dio.dart';
import 'package:familychat_app/core/constants/api_error_messages.dart';
import 'package:familychat_app/core/network/dio_jwt_error.dart';
import 'package:flutter_test/flutter_test.dart';

DioException _err({
  required int status,
  Map<String, dynamic>? data,
  String? authorization,
}) {
  return DioException(
    requestOptions: RequestOptions(
      path: '/familychat/gallery/albums/',
      headers: {
        if (authorization != null) 'Authorization': authorization,
      },
    ),
    response: Response(
      requestOptions: RequestOptions(path: '/familychat/gallery/albums/'),
      statusCode: status,
      data: data,
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  test('credentials-missing 403 must restore session', () {
    final err = _err(
      status: 403,
      data: {'detail': 'Учетные данные не были предоставлены.'},
    );
    expect(dioErrorNeedsAuthRestore(err), isTrue);
    expect(userFacingErrorMessage(err), 'Нужно войти заново.');
  });

  test('English authentication credentials 403 must restore session', () {
    final err = _err(
      status: 403,
      data: {'detail': 'Authentication credentials were not provided.'},
    );
    expect(dioErrorNeedsAuthRestore(err), isTrue);
    expect(userFacingErrorMessage(err), 'Нужно войти заново.');
  });

  test('403 without Authorization header must restore session', () {
    final err = _err(status: 403, data: {'detail': 'Forbidden'});
    expect(dioErrorNeedsAuthRestore(err), isTrue);
  });

  test('real permission 403 with Bearer must not restore session', () {
    final err = _err(
      status: 403,
      authorization: 'Bearer abc',
      data: {'detail': 'Нет доступа'},
    );
    expect(dioErrorNeedsAuthRestore(err), isFalse);
    expect(dioErrorIsExpiredJwtAccess(err), isFalse);
    expect(userFacingErrorMessage(err), 'Нет доступа');
  });

  test('401 always restores session', () {
    final err = _err(status: 401, data: {'detail': 'token_not_valid'});
    expect(dioErrorNeedsAuthRestore(err), isTrue);
    expect(userFacingErrorMessage(err), 'Нужно войти заново.');
  });

  test('client-side restore failure is not a raw 403', () {
    final err = DioException(
      requestOptions: RequestOptions(path: '/familychat/gallery/albums/'),
      type: DioExceptionType.unknown,
      error: kAuthRestoreFailed,
      message: 'Нужно войти заново.',
    );
    expect(dioErrorIsAuthRestoreFailure(err), isTrue);
    expect(userFacingErrorMessage(err), 'Нужно войти заново.');
  });
}
