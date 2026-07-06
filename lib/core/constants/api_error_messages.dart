import 'package:dio/dio.dart';

String userFacingErrorMessage(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['detail'] != null) {
      return data['detail'].toString();
    }
    final code = error.response?.statusCode;
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
