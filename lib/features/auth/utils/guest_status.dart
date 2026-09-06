import '../../../core/storage/guest_session_storage.dart';
import '../data/auth_repository.dart';

abstract final class GuestStatus {
  static bool fromStatusMap(Map<String, dynamic>? status) {
    if (status == null) return false;
    final v = status['is_guest'];
    return v == true || v == 1 || v?.toString().toLowerCase() == 'true';
  }

  static Future<bool> resolve({
    Map<String, dynamic>? status,
    AuthRepository? auth,
  }) async {
    if (fromStatusMap(status)) return true;
    if (await GuestSessionStorage.isActiveGuestSession()) return true;
    if (auth == null) return false;
    return auth.syncGuestSessionFlag();
  }
}
