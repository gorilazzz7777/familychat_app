import 'package:dio/dio.dart';

/// Detect ISO country from public IP. Falls back to null on failure.
Future<String?> detectCountryIsoFromIp() async {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
      responseType: ResponseType.plain,
    ),
  );
  try {
    final r = await dio.get<String>('https://ipapi.co/country_code/');
    final code = r.data?.trim().toUpperCase();
    if (code != null && code.length == 2) return code;
  } catch (_) {}
  try {
    final r = await dio.get<dynamic>(
      'http://ip-api.com/json/',
      queryParameters: {'fields': 'countryCode'},
      options: Options(responseType: ResponseType.json),
    );
    final code = (r.data is Map ? r.data['countryCode'] : null)?.toString();
    if (code != null && code.length == 2) return code.toUpperCase();
  } catch (_) {}
  return null;
}

/// MTProto proxy is for RU censorship bypass only.
///
/// - `RU` → use proxy  
/// - other countries → direct  
/// - detection failed → use proxy (safer for RU users)
Future<bool> shouldUseTdlibMtprotoProxy() async {
  final iso = await detectCountryIsoFromIp();
  if (iso == null) return true;
  return iso == 'RU';
}
