import 'package:flutter/foundation.dart';

import '../../familychat/data/familychat_repository.dart';
import 'chat_network_status.dart';
import 'chat_offline_outbox.dart';
import 'chat_offline_prefetch.dart';
import 'chat_scheduled_send_service.dart';

/// Координатор офлайн-кэша чатов и синхронизации очереди.
class ChatOfflineSync extends ChangeNotifier {
  ChatOfflineSync._();

  static final ChatOfflineSync instance = ChatOfflineSync._();

  bool _online = true;
  bool _syncing = false;
  List<ChatOutboxDelivery> _recentDeliveries = const [];

  bool get isOnline => _online;
  bool get isSyncing => _syncing;

  List<ChatOutboxDelivery> consumeDeliveries() {
    final items = _recentDeliveries;
    _recentDeliveries = const [];
    return items;
  }

  Future<bool> refreshOnline(FamilyChatRepository repo) async {
    final online = await ChatNetworkStatus.isOnline(() async {
      await repo.status();
    });
    if (_online != online) {
      _online = online;
      notifyListeners();
    }
    return online;
  }

  Future<void> run(FamilyChatRepository repo) async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();
    try {
      final online = await refreshOnline(repo);
      if (!online) return;

      final deliveries = await ChatOfflineOutbox.sync(repo);
      if (deliveries.isNotEmpty) {
        _recentDeliveries = deliveries;
        notifyListeners();
      }

      await ChatOfflinePrefetch.run(repo);
      await ChatScheduledSendService.instance.dispatchDue();
      notifyListeners();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }
}
