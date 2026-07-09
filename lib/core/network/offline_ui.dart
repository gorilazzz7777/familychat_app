import '../../features/chat/data/chat_network_status.dart';
import '../../features/chat/data/chat_offline_sync.dart';

/// Вспомогательные методы для экранов без сети.
abstract final class OfflineUi {
  static bool get isOffline => !ChatOfflineSync.instance.isOnline;

  /// Не показывать технические ошибки, когда проблема в сети.
  static String? loadErrorMessage(Object? error, {String? fallback}) {
    if (isOffline || ChatNetworkStatus.looksOffline(error)) return null;
    return fallback ?? 'Не удалось загрузить данные';
  }
}
