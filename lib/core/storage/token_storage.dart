import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStorage {
  TokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              webOptions: WebOptions(
                dbName: 'familychat_secure_storage',
                publicKey: 'familychat_secure_storage',
              ),
            );

  final FlutterSecureStorage _storage;
  static const _access = 'fc_access';
  static const _refresh = 'fc_refresh';

  Future<void> saveTokens({required String access, required String refresh}) async {
    await _storage.write(key: _access, value: access);
    await _storage.write(key: _refresh, value: refresh);
  }

  Future<void> saveAccess(String access) => _storage.write(key: _access, value: access);

  Future<String?> readAccess() => _storage.read(key: _access);

  Future<String?> readRefresh() => _storage.read(key: _refresh);

  Future<bool> hasRefreshCredential() async {
    final r = await readRefresh();
    return r != null && r.isNotEmpty;
  }

  Future<void> clear() async {
    await _storage.delete(key: _access);
    await _storage.delete(key: _refresh);
  }
}
