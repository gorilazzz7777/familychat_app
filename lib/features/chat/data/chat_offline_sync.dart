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
  DateTime? _lastOnlineCheckAt;
  DateTime? _syncStartedAt;

  /// Skip /status ping when we recently confirmed online (send path latency).
  static const _onlineCheckTtl = Duration(seconds: 10);

  bool get isOnline => _online;
  bool get isSyncing => _syncing;

  /// Явно выставить флаг (холодный старт из кэша при отсутствии сети).
  void setOnline(bool online) {
    if (_online == online) {
      if (!online) _lastOnlineCheckAt = null;
      return;
    }
    _online = online;
    _lastOnlineCheckAt = online ? DateTime.now() : null;
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

  Future<bool> refreshOnline(
    FamilyChatRepository repo, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _online &&
        _lastOnlineCheckAt != null &&
        now.difference(_lastOnlineCheckAt!) < _onlineCheckTtl) {
      return true;
    }
    final sw = Stopwatch()..start();
    final online = await ChatNetworkStatus.isOnline(() async {
      await repo.status(timeout: const Duration(seconds: 3));
    });
    if (kDebugMode) {
      debugPrint(
        '[ChatOfflineSync] online_ping ${sw.elapsedMilliseconds}ms -> $online',
      );
    }
    _lastOnlineCheckAt = now;
    if (_online != online) {
      _online = online;
      if (!online) _lastOnlineCheckAt = null;
      notifyListeners();
    }
    return online;
  }

  Future<void> run(FamilyChatRepository repo) async {
    _pendingRepo = repo;
    // Every caller marks work pending. The active loop drains until clear.
    _rerunRequested = true;
    if (_syncing) {
      return;
    }
    _syncing = true;
    _syncStartedAt = DateTime.now();
    _retryTimer?.cancel();
    var shouldPrefetch = false;
    var passes = 0;
    try {
      while (_rerunRequested) {
        _rerunRequested = false;
        passes++;
        final activeRepo = _pendingRepo ?? repo;
        // Never block the outbox on /status: a slow ping (tens of seconds
        // behind Dio traffic) was delaying sends by queue_wait≈10s+.
        if (!_online) {
          final online = await refreshOnline(activeRepo, force: true);
          if (!online) break;
        }

        final result = await ChatOfflineOutbox.sync(activeRepo);
        if (result.deliveries.isNotEmpty) {
          _recentDeliveries = [..._recentDeliveries, ...result.deliveries];
          notifyListeners();
        }
        if (result.nextRetryAt != null) {
          _scheduleRetry(activeRepo, result.nextRetryAt!);
        }
      }
      shouldPrefetch = _online;
    } finally {
      final again = _pendingRepo;
      // Drop the lock before reading the dirty flag so a concurrent run()
      // either sets _rerunRequested or starts a new worker — never both lost.
      _syncing = false;
      _syncStartedAt = null;
      if (_rerunRequested && again != null) {
        if (kDebugMode) {
          debugPrint(
            '[ChatOfflineSync] run chain passes=$passes -> rerun',
          );
        }
        unawaited(run(again));
      } else {
        if (kDebugMode) {
          debugPrint('[ChatOfflineSync] run done passes=$passes');
        }
        if (again != null) {
          if (_online) {
            unawaited(ChatScheduledSendService.instance.dispatchDue());
          }
          if (shouldPrefetch) {
            unawaited(_runPrefetch(again));
          }
        }
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
