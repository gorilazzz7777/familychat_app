import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../../core/media/media_incoming_sync.dart';
import '../../../core/notifications/familychat_foreground_bridge.dart';
import '../../familychat/data/familychat_repository.dart';
import 'active_chat_context.dart';
import 'chat_bootstrap_coordinator.dart';
import 'chat_local_mutations.dart';
import 'chat_message_preview.dart';
import 'chat_offline_outbox.dart';
import 'chat_realtime_utils.dart';
import 'chat_send_trace.dart';
import 'chat_unread_providers.dart';
import 'familychat_realtime.dart';

/// Fills local SQLite from HTTP + WebSocket. UI must not call the network for display.
class ChatSyncService {
  ChatSyncService._();

  static final ChatSyncService instance = ChatSyncService._();

  FamilyChatRepository? _repo;
  int? _currentUserId;
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

  Future<void> start(FamilyChatRepository repo, {int? currentUserId}) async {
    if (!isSupported) return;
    _repo = repo;
    _currentUserId = currentUserId;
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

  void setCurrentUserId(int? userId) {
    _currentUserId = userId;
  }

  Future<void> stop() async {
    _historyTimer?.cancel();
    _historyTimer = null;
    if (_listening) {
      FamilyChatRealtime.instance.removeListener(_onRealtime);
      _listening = false;
    }
    _repo = null;
    _currentUserId = null;
  }

  void _notifyUnreadChanged() {
    ChatUnreadRefresh.onInvalidate?.call();
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
      unawaited(_applyMessagesRead(threadId, ids));
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
      final force = event['force'] == true;
      if (threadId != null) {
        // Push / thread wake: messages alone do not bump hub unread.
        unawaited(_syncThreadAndHubRow(threadId));
      } else {
        unawaited(syncHub(prefetchMessages: true, force: force));
      }
    }
  }

  bool _messageIsMine(Map<String, dynamic> message) {
    return chatMessageIsMine(message, _currentUserId);
  }

  Future<void> _applyMessagesRead(int threadId, List<int> messageIds) async {
    await ChatLocalStore.instance.markMessagesRead(threadId, messageIds);
    final idSet = messageIds.toSet();
    final threads = await ChatLocalStore.instance.readThreads();
    for (final thread in threads) {
      if (chatAsInt(thread['id']) != threadId) continue;
      final last = thread['last_message'];
      if (last is! Map) break;
      final lastId = chatAsInt(last['id']);
      if (lastId == null || !idSet.contains(lastId)) break;
      final lastMap = Map<String, dynamic>.from(last);
      lastMap['read_status'] = chatMergeReadStatus(
        lastMap['read_status']?.toString(),
        'read',
      );
      await ChatLocalStore.instance.upsertThread({
        ...thread,
        'last_message': lastMap,
      });
      _notifyUnreadChanged();
      break;
    }
  }

  Future<void> _ingestIncomingMessage(Map<String, dynamic> message) async {
    final threadId = chatAsInt(message['thread_id']);
    if (threadId == null) return;
    final messageId = chatAsInt(message['id']);
    if (messageId != null &&
        ChatOfflineOutbox.isMessagePendingRemoval(threadId, messageId)) {
      return;
    }

    final owned = chatEnsureMessageOwnership(
      message,
      currentUserId: _currentUserId,
    );
    ChatSendTrace.log(
      'realtime_ingest',
      threadId: threadId,
      serverId: messageId,
      source: 'sync',
    );
    await ChatLocalStore.instance.upsertMessage(owned);
    unawaited(MediaIncomingSync.ensureMessages([owned]));
    await _dropMatchingPending(
      threadId,
      owned,
      currentUserId: _currentUserId,
    );

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
      thread['last_message'] = owned;
      var unread = chatAsInt(thread['unread_count']) ?? 0;
      final viewing =
          FamilyChatForegroundBridge.isActivelyViewingThread(threadId);
      final isMine = _messageIsMine(owned);
      if (!viewing && !isMine && !chatMessageIsPending(owned)) {
        unread += 1;
      }
      thread['unread_count'] = unread;
      await ChatLocalStore.instance.upsertThread(thread);
      _notifyUnreadChanged();
    } else {
      unawaited(syncHub(force: true));
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
    ChatSendTrace.log(
      'sync_drop_matching_pending',
      threadId: threadId,
      tempId: candidates.first.id,
      serverId: chatAsInt(serverMessage['id']),
      source: 'sync',
      extra: {'deltaMs': candidates.first.delta},
    );
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
        // Активный outbox / незавершённая отправка — не удаляем по слабому матчу.
        if (status == 'sending' ||
            status == 'queued' ||
            status == 'sent' ||
            status == 'failed') {
          continue;
        }
        toDelete.add(id);
      }
    }
    if (toDelete.isNotEmpty) {
      ChatSendTrace.log(
        'sync_reconcile_delete',
        threadId: threadId,
        source: 'sync',
        extra: {'ids': toDelete.join(',')},
      );
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
      final remoteThreads = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      final localThreads = await ChatLocalStore.instance.readThreads();
      final localById = <int, Map<String, dynamic>>{
        for (final t in localThreads)
          if (chatAsInt(t['id']) != null) chatAsInt(t['id'])!: t,
      };
      final threads = [
        for (final server in remoteThreads)
          _mergeHubThread(server, localById[chatAsInt(server['id'])]),
      ];
      final enriched = await enrichChatThreadsLastMessages(threads);
      await ChatLocalStore.instance.replaceThreads(enriched);
      await ChatLocalStore.instance.replaceMembers(members);
      _notifyUnreadChanged();

      if (prefetchMessages) {
        for (final thread in enriched) {
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

  /// Keep optimistic WS unread/preview when HTTP hub snapshot is slightly stale.
  Map<String, dynamic> _mergeHubThread(
    Map<String, dynamic> server,
    Map<String, dynamic>? local,
  ) {
    if (local == null) return server;
    final serverUnread = chatAsInt(server['unread_count']) ?? 0;
    final localUnread = chatAsInt(local['unread_count']) ?? 0;
    final serverLast = server['last_message'];
    final localLast = local['last_message'];
    final serverLastMap = serverLast is Map
        ? Map<String, dynamic>.from(serverLast)
        : null;
    final localLastMap =
        localLast is Map ? Map<String, dynamic>.from(localLast) : null;
    final serverLastId = serverLastMap == null
        ? null
        : chatAsInt(serverLastMap['id']);
    final localLastId =
        localLastMap == null ? null : chatAsInt(localLastMap['id']);

    if (localLastId != null &&
        (serverLastId == null || localLastId > serverLastId)) {
      return {
        ...server,
        'last_message': localLastMap,
        'unread_count': math.max(serverUnread, localUnread),
      };
    }
    if (localLastId != null && localLastId == serverLastId) {
      final richer = chatPreferRicherLastMessage(serverLastMap, localLastMap);
      return {
        ...server,
        'last_message': richer,
        if (localUnread > serverUnread) 'unread_count': localUnread,
      };
    }
    return server;
  }

  Future<void> _patchHubLastMessageFromSynced(
    int threadId,
    List<Map<String, dynamic>> messages,
  ) async {
    if (messages.isEmpty) return;
    Map<String, dynamic>? newest;
    var newestId = -1;
    for (final message in messages) {
      final id = chatAsInt(message['id']);
      if (id == null || id <= 0 || chatMessageIsPending(message)) continue;
      if (id >= newestId) {
        newestId = id;
        newest = message;
      }
    }
    if (newest == null) return;

    final threads = await ChatLocalStore.instance.readThreads();
    for (final thread in threads) {
      if (chatAsInt(thread['id']) != threadId) continue;
      final last = thread['last_message'];
      final lastMap =
          last is Map ? Map<String, dynamic>.from(last) : null;
      final lastId = lastMap == null ? null : chatAsInt(lastMap['id']);
      if (lastId != null && lastId > newestId) return;
      final richer = lastId == newestId
          ? chatPreferRicherLastMessage(lastMap, newest)
          : newest;
      await ChatLocalStore.instance.upsertThread({
        ...thread,
        'last_message': richer,
      });
      _notifyUnreadChanged();
      return;
    }
  }

  Future<void> _syncThreadAndHubRow(int threadId) async {
    await syncThread(threadId);
    final repo = _repo;
    if (repo == null) return;
    try {
      final threads = await repo.chatThreads();
      Map<String, dynamic>? match;
      for (final t in threads) {
        if (chatAsInt(t['id']) == threadId) {
          match = chatNormalizeMap(Map<dynamic, dynamic>.from(t));
          break;
        }
      }
      if (match == null) return;
      final localThreads = await ChatLocalStore.instance.readThreads();
      Map<String, dynamic>? local;
      for (final t in localThreads) {
        if (chatAsInt(t['id']) == threadId) {
          local = t;
          break;
        }
      }
      await ChatLocalStore.instance.upsertThread(_mergeHubThread(match, local));
      _notifyUnreadChanged();
    } catch (e, st) {
      debugPrint('[ChatSyncService] hub row refresh failed: $e\n$st');
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
      final markRead =
          FamilyChatForegroundBridge.isActivelyViewingThread(threadId);
      final page = await repo.threadMessages(
        threadId,
        limit: limit,
        markRead: markRead,
      );
      final blocked =
          await ChatOfflineOutbox.pendingRemovalMessageIds(threadId: threadId);
      final rawMessages = blocked.isEmpty
          ? page.messages
          : page.messages
              .where((m) {
                final id = chatAsInt(m['id']);
                return id == null || !blocked.contains(id);
              })
              .toList(growable: false);
      final messages = [
        for (final m in rawMessages)
          chatEnsureMessageOwnership(m, currentUserId: _currentUserId),
      ];
      await ChatLocalStore.instance.upsertMessages(threadId, messages);
      await _patchHubLastMessageFromSynced(threadId, messages);
      if (page.pinnedMessages.isNotEmpty) {
        final pins = blocked.isEmpty
            ? page.pinnedMessages
            : page.pinnedMessages
                .where((m) {
                  final id = chatAsInt(m['id']);
                  return id == null || !blocked.contains(id);
                })
                .toList(growable: false);
        await ChatLocalMutations.savePinnedMessagesLocal(threadId, pins);
      }
      final keepIds = <int>{
        for (final m in messages)
          if (chatAsInt(m['id']) != null && chatAsInt(m['id'])! > 0)
            chatAsInt(m['id'])!,
        // Keep tombstoned ids out of deleteMissing? They're already deleted
        // locally; excluding them from keepIds is correct so they stay gone.
      };
      if (keepIds.isNotEmpty) {
        final minId = keepIds.reduce((a, b) => a < b ? a : b);
        final maxId = keepIds.reduce((a, b) => a > b ? a : b);
        ChatSendTrace.log(
          'sync_thread_window',
          threadId: threadId,
          source: 'sync',
          extra: {
            'messages': messages.length,
            'keepMin': minId,
            'keepMax': maxId,
            'keepCount': keepIds.length,
          },
        );
        await ChatLocalStore.instance.deleteMissingFromWindow(
          threadId: threadId,
          minId: minId,
          maxId: maxId,
          keepIds: keepIds,
        );
      }
      // Ensure SQLite stays clear for in-flight deletions even if upsert raced.
      if (blocked.isNotEmpty) {
        await ChatLocalStore.instance.deleteMessages(
          threadId,
          blocked.toList(growable: false),
        );
      }
      unawaited(MediaIncomingSync.ensureMessages(messages));
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
      final blocked =
          await ChatOfflineOutbox.pendingRemovalMessageIds(threadId: threadId);
      final rawMessages = blocked.isEmpty
          ? page.messages
          : page.messages
              .where((m) {
                final id = chatAsInt(m['id']);
                return id == null || !blocked.contains(id);
              })
              .toList(growable: false);
      final messages = [
        for (final m in rawMessages)
          chatEnsureMessageOwnership(m, currentUserId: _currentUserId),
      ];
      await ChatLocalStore.instance.upsertMessages(threadId, messages);
      if (blocked.isNotEmpty) {
        await ChatLocalStore.instance.deleteMessages(
          threadId,
          blocked.toList(growable: false),
        );
      }
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
        final blocked = await ChatOfflineOutbox.pendingRemovalMessageIds(
          threadId: threadId,
        );
        final rawMessages = blocked.isEmpty
            ? page.messages
            : page.messages
                .where((m) {
                  final id = chatAsInt(m['id']);
                  return id == null || !blocked.contains(id);
                })
                .toList(growable: false);
        final messages = [
          for (final m in rawMessages)
            chatEnsureMessageOwnership(m, currentUserId: _currentUserId),
        ];
        await ChatLocalStore.instance.upsertMessages(threadId, messages);
        if (blocked.isNotEmpty) {
          await ChatLocalStore.instance.deleteMessages(
            threadId,
            blocked.toList(growable: false),
          );
        }
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