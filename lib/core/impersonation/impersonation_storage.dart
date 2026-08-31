import 'package:shared_preferences/shared_preferences.dart';

class ImpersonationStorage {
  static const _activeKey = 'impersonation_ro_active';
  static const _backupAccessKey = 'impersonation_backup_access';
  static const _backupRefreshKey = 'impersonation_backup_refresh';

  static bool? _cachedActive;

  Future<bool> isActive() async {
    if (_cachedActive != null) return _cachedActive!;
    final prefs = await SharedPreferences.getInstance();
    _cachedActive = prefs.getBool(_activeKey) ?? false;
    return _cachedActive!;
  }

  Future<void> markActive() async {
    _cachedActive = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_activeKey, true);
  }

  Future<void> clear() async {
    _cachedActive = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeKey);
    await prefs.remove(_backupAccessKey);
    await prefs.remove(_backupRefreshKey);
  }

  Future<void> backupCurrentSessionIfNeeded({
    required Future<String?> Function() readAccess,
    required Future<String?> Function() readRefresh,
  }) async {
    if (await isActive()) return;
    final access = await readAccess();
    final refresh = await readRefresh();
    if (access == null ||
        refresh == null ||
        access.isEmpty ||
        refresh.isEmpty) {
      return;
    }
    await backupTokens(access: access, refresh: refresh);
  }

  Future<void> backupTokens({
    required String access,
    required String refresh,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backupAccessKey, access);
    await prefs.setString(_backupRefreshKey, refresh);
  }

  Future<({String? access, String? refresh})> readBackup() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      access: prefs.getString(_backupAccessKey),
      refresh: prefs.getString(_backupRefreshKey),
    );
  }
}
