import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_network_status.dart';
import 'chat_offline_outbox.dart';
import 'chat_offline_prefetch.dart';
import 'chat_realtime_utils.dart';
import 'chat_scheduled_send_service.dart';

/// Координатор офлайн-кэша чатов и синхронизации очереди.
class ChatOfflineSync extends ChangeNotifier {
  ChatOfflineSync._();

  static final ChatOfflineSync instance = ChatOfflineSync._();

  bool _online = true;
  bool _syncing = false;
  bool _rerunRequested = false;
  int _stuckRetries = 0;
  FamilyChatRepository? _pendingRepo;
  List<ChatOutboxDelivery> _recentDeliveries = const [];

  bool get isOnline => _online;
  bool get isSyncing => _syncing;

  /// Явно выставить флаг (холодный старт из кэша при отсутствии сети).
  void setOnline(bool online) {
    if (_online == online) return;
    _online = online;
    notifyListeners();
  }

  List<ChatOutboxDelivery> consumeDeliveries() {
    final items = _recentDeliveries;
    _recentDeliveries = const [];
    return items;
  }

  /// Take deliveries for one thread without discarding others.
  List<ChatOutboxDelivery> takeDeliveriesForThread(int threadId) {
    final forThread =
        _recentDeliveries.where((d) => d.threadId == threadId).toList();
    if (forThread.isEmpty) return const [];
    _recentDeliveries =
        _recentDeliveries.where((d) => d.threadId != threadId).toList();
    return forThread;
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
    if (_syncing) {
      // Messages enqueued while a pass is running must not be dropped.
      _rerunRequested = true;
      _pendingRepo = repo;
      return;
    }
    _syncing = true;
    _pendingRepo = repo;
    notifyListeners();
    var hadFailuresOrRemaining = false;
    try {
      while (true) {
        _rerunRequested = false;
        final activeRepo = _pendingRepo ?? repo;
        final online = await refreshOnline(activeRepo);
        if (!online) break;

        final deliveries = await ChatOfflineOutbox.sync(activeRepo);
        final afterCount = await ChatOfflineOutbox.pendingCount();
        if (afterCount == 0) {
          _stuckRetries = 0;
        } else if (_stuckRetries < 3) {
          // Failed/skipped items stay in the queue; retry a few times.
          hadFailuresOrRemaining = true;
          _stuckRetries++;
        }
        if (deliveries.isNotEmpty) {
          _recentDeliveries = [..._recentDeliveries, ...deliveries];
          notifyListeners();
        }

        await ChatScheduledSendService.instance.dispatchDue();
        if (!_rerunRequested) break;
      }

      // Prefetch after outbox is drained so it never blocks follow-up sends.
      final activeRepo = _pendingRepo ?? repo;
      if (_online) {
        await ChatOfflinePrefetch.run(activeRepo);
        if (ChatLocalStore.isSupported) {
          final threads = await ChatLocalStore.instance.readThreads();
          final unreadIds = <int>[];
          for (final thread in threads) {
            final id = chatAsInt(thread['id']);
            if (id == null) continue;
            if ((chatAsInt(thread['unread_count']) ?? 0) > 0) {
              unreadIds.add(id);
            }
          }
          if (unreadIds.isNotEmpty) {
            unawaited(
              ChatOfflinePrefetch.prefetchThreads(activeRepo, unreadIds),
            );
          }
        }
      }
      notifyListeners();
    } finally {
      _syncing = false;
      final needsRerun = _rerunRequested || hadFailuresOrRemaining;
      final again = _pendingRepo;
      _rerunRequested = false;
      notifyListeners();
      if (needsRerun && again != null) {
        // Brief delay so a poison item does not tight-loop the CPU.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            unawaited(run(again));
          }),
        );
      }
    }
  }
}
