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
  FamilyChatRepository? _pendingRepo;
  List<ChatOutboxDelivery> _recentDeliveries = const [];
  Timer? _retryTimer;

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
    _retryTimer?.cancel();
    notifyListeners();
    var shouldPrefetch = false;
    try {
      while (true) {
        _rerunRequested = false;
        final activeRepo = _pendingRepo ?? repo;
        final online = await refreshOnline(activeRepo);
        if (!online) break;

        final result = await ChatOfflineOutbox.sync(activeRepo);
        if (result.deliveries.isNotEmpty) {
          _recentDeliveries = [..._recentDeliveries, ...result.deliveries];
          notifyListeners();
        }
        if (result.nextRetryAt != null) {
          _scheduleRetry(activeRepo, result.nextRetryAt!);
        }

        await ChatScheduledSendService.instance.dispatchDue();
        if (!_rerunRequested) break;
      }
      shouldPrefetch = _online;
    } finally {
      _syncing = false;
      final needsRerun = _rerunRequested;
      final again = _pendingRepo;
      _rerunRequested = false;
      notifyListeners();
      if (needsRerun && again != null) {
        // Prefer draining outbox immediately; prefetch must not delay sends.
        unawaited(run(again));
      } else if (shouldPrefetch && again != null) {
        // Prefetch outside _syncing so a new send can start sync right away.
        unawaited(_runPrefetch(again));
      }
    }
  }

  Future<void> _runPrefetch(FamilyChatRepository repo) async {
    try {
      await ChatOfflinePrefetch.run(repo);
      if (!ChatLocalStore.isSupported) return;
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
        unawaited(ChatOfflinePrefetch.prefetchThreads(repo, unreadIds));
      }
    } catch (e, st) {
      debugPrint('[ChatOfflineSync] prefetch failed: $e\n$st');
    }
  }

  void _scheduleRetry(FamilyChatRepository repo, DateTime at) {
    _retryTimer?.cancel();
    var delay = at.difference(DateTime.now().toUtc());
    if (delay.isNegative) delay = Duration.zero;
    _retryTimer = Timer(delay, () {
      unawaited(run(repo));
    });
  }
}
