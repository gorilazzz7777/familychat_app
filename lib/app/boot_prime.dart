import 'package:flutter/foundation.dart';

import '../core/cache/familychat_local_cache.dart';
import '../features/auth/session/local_anonymous.dart';

/// Cold-start status primed before [runApp] so Bootstrap can paint Shell
/// on frame 0 (no Flutter «Загрузка…» flash for returning users).
abstract final class BootPrime {
  static Map<String, dynamic>? _status;

  /// Read cached session status with a short budget. Safe to call from [main].
  static Future<void> warm([
    Duration budget = const Duration(milliseconds: 150),
  ]) async {
    if (kIsWeb) return;
    try {
      final status = await FamilyChatLocalCache.readStatus().timeout(budget);
      if (status == null || status.isEmpty) return;
      if (isLocalAnonymousStatus(status)) return;
      _status = status;
    } catch (_) {
      // Miss / slow disk — Bootstrap falls back to spinner path.
    }
  }

  /// Consume primed status once (null after take).
  static Map<String, dynamic>? takeStatus() {
    final status = _status;
    _status = null;
    return status;
  }
}
