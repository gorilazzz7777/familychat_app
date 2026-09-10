import '../../../core/local_db/chat_local_store.dart';
import 'chat_realtime_utils.dart';
import 'chat_unread_providers.dart';

/// Keep chat-list `last_message` aligned with messages still visible locally.
abstract final class ChatHubLastMessage {
  /// Rebuild hub preview from remaining local messages (after delete/hide).
  static Future<void> recompute(int threadId) async {
    if (!ChatLocalStore.isSupported) return;
    final threads = await ChatLocalStore.instance.readThreads();
    Map<String, dynamic>? thread;
    for (final row in threads) {
      if (chatAsInt(row['id']) == threadId) {
        thread = Map<String, dynamic>.from(row);
        break;
      }
    }
    if (thread == null) return;

    final tail = await ChatLocalStore.instance.readMessagesTail(
      threadId,
      limit: 80,
    );

    Map<String, dynamic>? newestServer;
    var newestServerId = -1;
    Map<String, dynamic>? newestPending;
    DateTime? newestPendingAt;

    for (final message in tail) {
      final id = chatAsInt(message['id']);
      if (chatMessageIsPending(message)) {
        final created = DateTime.tryParse(
              message['created_at']?.toString() ?? '',
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        if (newestPendingAt == null || created.isAfter(newestPendingAt)) {
          newestPendingAt = created;
          newestPending = Map<String, dynamic>.from(message);
        }
        continue;
      }
      if (id != null && id >= newestServerId) {
        newestServerId = id;
        newestServer = Map<String, dynamic>.from(message);
      }
    }

    final tip = newestServer ?? newestPending;
    final next = Map<String, dynamic>.from(thread);
    if (tip == null) {
      next['last_message'] = null;
    } else {
      var payload = tip;
      if (payload['is_mine'] == true) {
        final status = payload['read_status']?.toString().trim() ?? '';
        if (status.isEmpty) {
          payload = {...payload, 'read_status': 'sent'};
        }
      }
      next['last_message'] = payload;
    }
    await ChatLocalStore.instance.upsertThread(next);
    ChatUnreadRefresh.onInvalidate?.call();
  }
}
