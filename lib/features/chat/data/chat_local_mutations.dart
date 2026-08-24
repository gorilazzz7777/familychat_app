import 'dart:convert';

import '../../../core/local_db/chat_local_store.dart';
import 'chat_realtime_utils.dart';
import 'chat_unread_providers.dart';

/// Optimistic SQLite updates before outbox sync (native local-first).
abstract final class ChatLocalMutations {
  static String _pinsMetaKey(int threadId) => 'pins_v1_$threadId';

  static Future<void> markThreadReadLocal(
    int threadId, {
    required int lastMessageId,
  }) async {
    if (!ChatLocalStore.isSupported) return;
    final threads = await ChatLocalStore.instance.readThreads();
    for (final thread in threads) {
      if (chatAsInt(thread['id']) != threadId) continue;
      final next = Map<String, dynamic>.from(thread);
      next['unread_count'] = 0;
      await ChatLocalStore.instance.upsertThread(next);
      break;
    }
    final messages = await ChatLocalStore.instance.readMessages(threadId);
    final ids = <int>[];
    for (final m in messages) {
      final id = chatAsInt(m['id']);
      if (id != null && id > 0 && id <= lastMessageId) {
        ids.add(id);
      }
    }
    if (ids.isNotEmpty) {
      await ChatLocalStore.instance.markMessagesRead(threadId, ids);
    }
    ChatUnreadRefresh.onInvalidate?.call();
  }

  static Future<void> patchThreadNotificationsLocal(
    int threadId,
    Map<String, dynamic> patch,
  ) async {
    if (!ChatLocalStore.isSupported) return;
    final threads = await ChatLocalStore.instance.readThreads();
    for (final thread in threads) {
      if (chatAsInt(thread['id']) != threadId) continue;
      final next = Map<String, dynamic>.from(thread);
      for (final entry in patch.entries) {
        next[entry.key] = entry.value;
      }
      await ChatLocalStore.instance.upsertThread(next);
      break;
    }
  }

  static Future<void> savePinnedMessagesLocal(
    int threadId,
    List<Map<String, dynamic>> pins,
  ) async {
    if (!ChatLocalStore.isSupported) return;
    await ChatLocalStore.instance.metaSet(
      _pinsMetaKey(threadId),
      jsonEncode(pins),
    );
  }

  static Future<List<Map<String, dynamic>>> readPinnedMessagesLocal(
    int threadId,
  ) async {
    if (!ChatLocalStore.isSupported) return const [];
    final raw = await ChatLocalStore.instance.metaGet(_pinsMetaKey(threadId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> patchMessageLocal(
    int threadId,
    int messageId,
    Map<String, dynamic> patch,
  ) async {
    if (!ChatLocalStore.isSupported) return;
    await ChatLocalStore.instance.patchMessageFields(
      threadId,
      messageId,
      patch,
    );
  }

  static Future<void> removeMessagesLocal(
    int threadId,
    List<int> messageIds,
  ) async {
    if (!ChatLocalStore.isSupported) return;
    if (messageIds.isEmpty) return;
    await ChatLocalStore.instance.deleteMessages(threadId, messageIds);
  }
}
