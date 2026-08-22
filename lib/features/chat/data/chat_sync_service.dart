import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../../core/media/media_incoming_sync.dart';
import '../../familychat/data/familychat_repository.dart';
import 'active_chat_context.dart';
import 'chat_bootstrap_coordinator.dart';
import 'chat_local_mutations.dart';
import 'chat_realtime_utils.dart';
import 'familychat_realtime.dart';

/// Fills local SQLite from HTTP + WebSocket. UI must not call the network for display.
class ChatSyncService {
  ChatSyncService._();

  static final ChatSyncService instance = ChatSyncService._();

  FamilyChatRepository? _repo;
  bool _listening = false;
  bool _syncingHub = false;
  bool _historySyncing = false;
  bool _deferredHubSync = false;
  bool _deferredHubPrefetch = false;
  Timer? _historyTimer;
  final Set<int> _syncingThreads = <int>{};
  final Map<int, Future<void>> _threadQueues = <int, Future<void>>{};

  static bool get isSupported => ChatLocalStore.isSupported;
  static const _historyCompletePrefix = 'hist_done_v1_';

  Future<void> start(FamilyChatRepository repo) async {
    if (!isSupported) return;
    _repo = repo;
    await ChatLocalStore.instance.ensureOpen();
    if (!_listening) {
      FamilyChatRealtime.instance.addListener(_onRealtime);
      _listening = true;
    }
    _historyTimer?.cancel();
    _historyTimer = Timer.periodic(const Duration(minutes: 12), (_) {
      unawaited(syncHistoriesInBackground());
    });
    unawaited(() async {
      await syncHub(prefetchMessages: true);
      unawaited(syncHistoriesInBackground());
    }());
  }

  Future<void> stop() async {
    _historyTimer?.cancel();
    _historyTimer = null;
    if (_listening) {
      FamilyChatRealtime.instance.removeListener(_onRealtime);
      _listening = false;
    }
    _repo = null;
  }

  void _onRealtime(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev == null) return;

    if (ev == 'chat_message') {
      final msg = event['message'];
      if (msg is! Map) return;
      final map = chatNormalizeMap(Map<dynamic, dynamic>.from(msg));
      map['thread_id'] ??= chatAsInt(event['thread_id']);
      unawaited(_ingestIncomingMessage(map));
      return;
    }

    if (ev == 'chat_messages_read') {
      final threadId = chatAsInt(event['thread_id']);
      final ids = chatAsIntList(event['message_ids']);
      if (threadId == null || ids.isEmpty) return;
      unawaited(ChatLocalStore.instance.markMessagesRead(threadId, ids));
      return;
    }

    if (ev == 'chat_messages_deleted') {
      final threadId = chatAsInt(event['thread_id']);
      final ids = chatAsIntList(event['message_ids']);
      if (threadId == null || ids.isEmpty) return;
      unawaited(ChatLocalStore.instance.deleteMessages(threadId, ids));
      return;
    }

    if (ev == 'chat_message_reactions') {
      final threadId = chatAsInt(event['thread_id']);
      final messageId = chatAsInt(event['message_id']);
      final reactions = event['reactions'];
      if (threadId == null || messageId == null || reactions is! List) return;
      unawaited(
        ChatLocalStore.instance.patchMessageFields(
          threadId,
          messageId,
          {'reactions': reactions},
        ),
      );
      return;
    }

    if (ev == 'chat_refresh') {
      final threadId = chatAsInt(event['thread_id']);
      if (threadId != null) {
        unawaited(syncThread(threadId));
      } else {
        unawaited(syncHub(prefetchMessages: true, force: false));
      }
    }
  }

  Future<void> _ingestIncomingMessage(Map<String, dynamic> message) async {
    final threadId = chatAsInt(message['thread_id']);
    if (threadId == null) return;

    await ChatLocalStore.instance.upsertMessage(message);
    unawaited(MediaIncomingSync.ensureMessages([message]));
    await _dropMatchingPending(threadId, message);

    // Patch thread preview/unread in local hub without waiting for HTTP.
    final threads = await ChatLocalStore.instance.readThreads();
    Map<String, dynamic>? thread;
    for (final t in threads) {
      if (chatAsInt(t['id']) == threadId) {
        thread = Map<String, dynamic>.from(t);
        break;
      }
    }
    if (thread != null) {
      thread['last_message'] = message;
      var unread = chatAsInt(thread['unread_count']) ?? 0;
      final viewing = ActiveChatContext.instance.isViewingThread(threadId);
      final isMine = message['is_mine'] == true;
      if (!viewing && !isMine && !chatMessageIsPending(message)) {
        unread += 1;
      }
      thread['unread_count'] = unread;
      await ChatLocalStore.instance.upsertThread(thread);
    } else {
      unawaited(syncHub(force: false));
    }
  }

  void _deferHubSync({bool prefetchMessages = false}) {
    _deferredHubSync = true;
    if (prefetchMessages) _deferredHubPrefetch = true;
  }

  /// Run hub sync that was skipped while the user was inside a conversation.
  Future<void> flushDeferredHubSync() async {
    if (!_deferredHubSync) return;
    _deferredHubSync = false;
    final prefetch = _deferredHubPrefetch;
    _deferredHubPrefetch = false;
    await syncHub(prefetchMessages: prefetch, force: true);
  }

  /// Remove optimistic/outbox rows that duplicate a confirmed server message.
  Future<void> _dropMatchingPending(
    int threadId,
    Map<String, dynamic> serverMessage, {
    int? currentUserId,
  }) async {
    if (chatMessageIsPending(serverMessage)) return;
    final rows = await ChatLocalStore.instance.readMessages(threadId);
    final candidates = <({int id, int delta})>[];
    final serverCreated =
        DateTime.tryParse(serverMessage['created_at']?.toString() ?? '');
    for (final row in rows) {
      if (!chatMessageIsPending(row) || row['_scheduled'] == true) continue;
      if (!chatPendingMatchesServer(
        row,
        serverMessage,
        currentUserId: currentUserId,
      )) {
        continue;
      }
      final id = chatAsInt(row['id']);
      if (id == null) continue;
      final pendingCreated =
          DateTime.tryParse(row['created_at']?.toString() ?? '');
      var delta = 0;
      if (pendingCreated != null && serverCreated != null) {
        delta =
            (pendingCreated.difference(serverCreated).inMilliseconds).abs();
      }
      candidates.add((id: id, delta: delta));
    }
    if (candidates.isEmpty) return;
    candidates.sort((a, b) => a.delta.compareTo(b.delta));
    await ChatLocalStore.instance.deleteMessages(threadId, [candidates.first.id]);
  }

  /// Reconcile stuck pending after a full thread window upsert.
  Future<void> _reconcileThreadPending(int threadId) async {
    final rows = await ChatLocalStore.instance.readMessages(threadId);
    final reconciled = chatReconcilePendingDuplicates(rows);
    if (reconciled.length == rows.length) return;
    final keptIds = <int>{
      for (final m in reconciled)
        if (chatAsInt(m['id']) != null) chatAsInt(m['id'])!,
    };
    final toDelete = <int>[];
    for (final row in rows) {
      final id = chatAsInt(row['id']);
      if (id == null) continue;
      if (chatMessageIsPending(row) &&
          row['_scheduled'] != true &&
          !keptIds.contains(id)) {
        final status = row['read_status']?.toString();
        // Активный outbox не трогаем по слабому матчу — только после deliver.
        if (status == 'sending' || status == 'queued') continue;
        toDelete.add(id);
      }
    }
    if (toDelete.isNotEmpty) {
      await ChatLocalStore.instance.deleteMessages(threadId, toDelete);
    }
  }

  Future<void> syncHub({
    bool prefetchMessages = false,
    bool force = false,
  }) async {
    var repo = _repo;
    if (!isSupported) return;
    if (repo == null) {
      debugPrint('[ChatSyncService] syncHub skipped: repo not attached yet');
      return;
    }
    if (!force && ActiveChatContext.instance.openThreadId != null) {
      _deferHubSync(prefetchMessages: prefetchMessages);
      return;
    }
    if (!force && ChatBootstrapCoordinator.instance.hubRecentlySynced) {
      return;
    }
    if (_syncingHub) return;
    await ChatBootstrapCoordinator.instance.syncHubOnce(
      repo,
      body: () => _syncHubBody(repo, prefetchMessages: prefetchMessages),
    );
  }

  Future<void> _syncHubBody(
    FamilyChatRepository repo, {
    required bool prefetchMessages,
  }) async {
    if (_syncingHub) return;
    _syncingHub = true;
    try {
      final results = await Future.wait([
        repo.chatThreads(),
        repo.members(),
      ]);
      final threads = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      await ChatLocalStore.instance.replaceThreads(threads);
      await ChatLocalStore.instance.replaceMembers(members);

      if (prefetchMessages) {
        for (final thread in threads) {
          final id = chatAsInt(thread['id']);
          if (id == null) continue;
          final unread = chatAsInt(thread['unread_count']) ?? 0;
          if (unread <= 0) continue;
          unawaited(syncThread(id));
        }
      }
    } catch (e, st) {
      debugPrint('[ChatSyncService] syncHub failed: $e\n$st');
    } finally {
      _syncingHub = false;
    }
  }

  Future<void> syncThread(int threadId, {int limit = 50}) {
    final existing = _threadQueues[threadId];
    if (existing != null) {
      return existing.then((_) => _syncThreadBody(threadId, limit: limit));
    }
    final future = _syncThreadBody(threadId, limit: limit);
    _threadQueues[threadId] = future;
    return future.whenComplete(() {
      if (identical(_threadQueues[threadId], future)) {
        _threadQueues.remove(threadId);
      }
    });
  }

  Future<void> _syncThreadBody(int threadId, {required int limit}) async {
    final repo = _repo;
    if (!isSupported || repo == null) return;
    if (_syncingThreads.contains(threadId)) return;
    _syncingThreads.add(threadId);
    try {
      final page = await repo.threadMessages(threadId, limit: limit);
      await ChatLocalStore.instance.upsertMessages(threadId, page.messages);
      if (page.pinnedMessages.isNotEmpty) {
        await ChatLocalMutations.savePinnedMessagesLocal(
          threadId,
          page.pinnedMessages,
        );
      }
      final keepIds = <int>{
        for (final m in page.messages)
          if (chatAsInt(m['id']) != null && chatAsInt(m['id'])! > 0)
            chatAsInt(m['id'])!,
      };
      if (keepIds.isNotEmpty) {
        await ChatLocalStore.instance.deleteMissingFromWindow(
          threadId: threadId,
          minId: keepIds.reduce((a, b) => a < b ? a : b),
          maxId: keepIds.reduce((a, b) => a > b ? a : b),
          keepIds: keepIds,
        );
      }
      unawaited(MediaIncomingSync.ensureMessages(page.messages));
      await _reconcileThreadPending(threadId);
    } catch (e, st) {
      debugPrint('[ChatSyncService] syncThread($threadId) failed: $e\n$st');
    } finally {
      _syncingThreads.remove(threadId);
    }
  }

  Future<void> syncThreadOlder(int threadId, {required int beforeId}) async {
    final repo = _repo;
    if (!isSupported || repo == null) return;
    try {
      final page = await repo.threadMessages(
        threadId,
        limit: 40,
        beforeId: beforeId,
      );
      await ChatLocalStore.instance.upsertMessages(threadId, page.messages);
    } catch (e, st) {
      debugPrint('[ChatSyncService] syncThreadOlder failed: $e\n$st');
    }
  }

  /// Push / reconnect wake: fetch newest window for a thread.
  Future<void> syncThreadFromPush(int threadId) =>
      syncThread(threadId, limit: 50);

  /// Newest page for [prioritizeThreadId] (and hub), then backfill full history
  /// for that thread and others in the background.
  Future<void> syncHistoriesInBackground({int? prioritizeThreadId}) async {
    if (!isSupported || _repo == null) return;
    if (_historySyncing) return;
    _historySyncing = true;
    try {
      if (ActiveChatContext.instance.openThreadId == null) {
        await syncHub(force: false);
      }
      final threads = await ChatLocalStore.instance.readThreads();
      final ids = <int>[
        if (prioritizeThreadId != null) prioritizeThreadId,
        for (final thread in threads)
          if (chatAsInt(thread['id']) != null &&
              chatAsInt(thread['id']) != prioritizeThreadId)
            chatAsInt(thread['id'])!,
      ];
      // Cap work per wake: prioritized thread fully, then a few others.
      const maxOtherThreads = 3;
      var othersDone = 0;
      for (final id in ids) {
        if (_repo == null) return;
        final isPriority = id == prioritizeThreadId;
        if (!isPriority && othersDone >= maxOtherThreads) break;
        await syncThread(id, limit: 80);
        await syncThreadHistory(
          id,
          maxPages: isPriority ? 6 : 2,
        );
        if (!isPriority) othersDone += 1;
        // Yield so UI/WS stay responsive.
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    } catch (e, st) {
      debugPrint('[ChatSyncService] syncHistoriesInBackground failed: $e\n$st');
    } finally {
      _historySyncing = false;
    }
  }

  Future<void> syncThreadHistory(int threadId, {int maxPages = 12}) async {
    final repo = _repo;
    if (!isSupported || repo == null) return;
    if (await _isHistoryComplete(threadId)) return;
    var pages = 0;
    while (pages < maxPages) {
      if (_repo == null) return;
      var oldest =
          await ChatLocalStore.instance.oldestServerMessageId(threadId);
      if (oldest == null) {
        await syncThread(threadId, limit: 80);
        pages += 1;
        oldest = await ChatLocalStore.instance.oldestServerMessageId(threadId);
        if (oldest == null) return;
      }
      try {
        final page = await repo.threadMessages(
          threadId,
          limit: 80,
          beforeId: oldest,
        );
        if (page.messages.isEmpty) {
          await _markHistoryComplete(threadId);
          return;
        }
        await ChatLocalStore.instance.upsertMessages(threadId, page.messages);
        pages += 1;
        if (!page.hasMore) {
          await _markHistoryComplete(threadId);
          return;
        }
      } catch (e, st) {
        debugPrint('[ChatSyncService] syncThreadHistory($threadId) failed: $e\n$st');
        return;
      }
    }
  }

  Future<bool> isThreadHistoryComplete(int threadId) =>
      _isHistoryComplete(threadId);

  Future<bool> _isHistoryComplete(int threadId) async {
    final flag = await ChatLocalStore.instance.metaGet(
      '$_historyCompletePrefix$threadId',
    );
    return flag == '1';
  }

  Future<void> _markHistoryComplete(int threadId) async {
    await ChatLocalStore.instance.metaSet(
      '$_historyCompletePrefix$threadId',
      '1',
    );
  }
}