/// Client app id for X-Client-App header.
abstract final class AppClient {
  static const headerName = 'X-Client-App';
  static const headerValue = 'familychat';

  static Map<String, String> get extraHeaders => const {
        headerName: headerValue,
      };
}