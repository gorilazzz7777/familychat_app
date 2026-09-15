/// Client app id and install store for backend analytics headers.
abstract final class AppClient {
  static const headerName = 'X-Client-App';
  static const headerValue = 'familychat';
  static const installStoreHeaderName = 'X-Install-Store';

  static String? _installStore;

  /// `play` | `rustore` | `unknown` — from [setInstallStore].
  static String? get installStore => _installStore;

  static void setInstallStore(String store) {
    final value = store.trim().toLowerCase();
    if (value.isEmpty) return;
    _installStore = value;
  }

  static Map<String, String> get extraHeaders {
    final headers = <String, String>{
      headerName: headerValue,
    };
    final store = _installStore;
    if (store != null && store.isNotEmpty) {
      headers[installStoreHeaderName] = store;
    }
    return headers;
  }
}
