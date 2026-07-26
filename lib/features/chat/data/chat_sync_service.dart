import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_realtime_utils.dart';
import 'familychat_realtime.dart';

/// Fills local SQLite from HTTP + WebSocket. UI must not call the network for display.
class ChatSyncService {
  ChatSyncService._();

  static final ChatSyncService instance = ChatSyncService._();

  FamilyChatRepository? _repo;
  bool _listening = false;
  bool _syncingHub = false;
  final Set<int> _syncingThreads = <int>{};
  final Map<int, Future<void>> _threadQueues = <int, Future<void>>{};

  static bool get isSupported => ChatLocalStore.isSupported;

  Future<void> start(FamilyChatRepository repo) async {
    if (!isSupported) return;
    _repo = repo;
    await ChatLocalStore.instance.ensureOpen();
    if (!_listening) {
      FamilyChatRealtime.instance.addListener(_onRealtime);
      _listening = true;
    }
    unawaited(syncHub());
  }

  Future<void> stop() async {
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
        unawaited(syncHub(prefetchMessages: true));
      }
    }
  }

  Future<void> _ingestIncomingMessage(Map<String, dynamic> message) async {
    final threadId = chatAsInt(message['thread_id']);
    if (threadId == null) return;

    final senderId = chatAsInt(message['sender_user_id']);
    // Drop optimistic pending rows from this device when server echo arrives.
    if (senderId != null) {
      // Keep other pending; syncThread will reconcile. Clear only exact pending
      // on upsert via store — handled by message id replace.
    }

    await ChatLocalStore.instance.upsertMessage(message);

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
      final unread = chatAsInt(thread['unread_count']) ?? 0;
      // Don't invent unread rules aggressively; hub sync corrects soon.
      thread['unread_count'] = unread;
      await ChatLocalStore.instance.upsertThread(thread);
    } else {
      unawaited(syncHub());
    }
  }

  Future<void> syncHub({bool prefetchMessages = false}) async {
    final repo = _repo;
    if (!isSupported || repo == null) return;
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
}