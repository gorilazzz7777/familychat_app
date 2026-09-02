import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/chat/data/chat_local_mutations.dart';
import '../../features/chat/data/chat_offline_outbox.dart';
import '../../features/chat/data/chat_ws_mark_read.dart';
import '../../features/familychat/data/familychat_repository.dart';
import '../../features/chat/data/chat_realtime_utils.dart';
import '../local_db/chat_local_store.dart';
import '../network/api_client.dart';
import 'chat_push_thread_preview.dart';
import 'push_reply_trace.dart';

/// «Прочитано» из шторки уведомлений — отмечает чат прочитанным.
abstract final class NotificationMarkRead {
  static const actionId = 'familychat_mark_read';
  static const markReadTimeout = Duration(seconds: 12);
  static const _dedupePrefix = 'push_mark_read_';
  static const _dedupeWindowMs = 5000;

  static final Set<int> _inFlight = {};

  @pragma('vm:entry-point')
  static Future<bool> markFromPayload({
    required Map<String, dynamic> data,
    String source = 'unknown',
  }) async {
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    if (threadId == null) {
      PushReplyTrace.log(
        'mark_read_skip_no_thread',
        source: source,
        extra: {'payloadKeys': data.keys.join(',')},
      );
      return false;
    }

    if (_inFlight.contains(threadId)) {
      PushReplyTrace.log(
        'mark_read_dedupe_inflight',
        threadId: threadId,
        source: source,
      );
      return true;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_dedupePrefix$threadId';
      final handledAt = prefs.getInt(key);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (handledAt != null && now - handledAt < _dedupeWindowMs) {
        PushReplyTrace.log(
          'mark_read_dedupe_skip',
          threadId: threadId,
          source: source,
        );
        return true;
      }
      await prefs.setInt(key, now);
    } catch (e) {
      PushReplyTrace.log(
        'mark_read_dedupe_error',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
    }

    _inFlight.add(threadId);
    try {
      await markThreadReadFromPush(
        threadId: threadId,
        data: data,
        source: source,
      );
      return true;
    } catch (e, st) {
      PushReplyTrace.log(
        'mark_read_fail',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
      debugPrint('[NotificationMarkRead] failed: $e\n$st');
      return false;
    } finally {
      _inFlight.remove(threadId);
    }
  }

  /// Отметить чат прочитанным до [sentMessageId] или последнего id из push/SQLite.
  static Future<void> markThreadReadFromPush({
    required int threadId,
    required Map<String, dynamic> data,
    int? sentMessageId,
    required String source,
  }) async {
    var lastId = sentMessageId ?? 0;
    final fromPayload = int.tryParse(data['message_id']?.toString() ?? '');
    if (fromPayload != null && fromPayload > lastId) {
      lastId = fromPayload;
    }

    if (ChatLocalStore.isSupported) {
      try {
        final newest = await ChatLocalStore.instance
            .newestServerMessageId(threadId)
            .timeout(const Duration(seconds: 2));
        if (newest != null && newest > lastId) {
          lastId = newest;
        }
      } catch (e) {
        PushReplyTrace.log(
          'mark_read_local_id_fail',
          threadId: threadId,
          source: source,
          detail: '$e',
        );
      }
    }

    if (lastId <= 0) {
      final fromPreview =
          await ChatPushThreadPreview.newestStoredMessageId(threadId);
      if (fromPreview != null && fromPreview > lastId) {
        lastId = fromPreview;
      }
    }

    if (lastId <= 0) {
      try {
        final client = ApiClient();
        final token = await client.tokenStorage.readAccess();
        if (token != null && token.isNotEmpty) {
          final threads = await FamilyChatRepository(client)
              .chatThreads()
              .timeout(markReadTimeout);
          for (final thread in threads) {
            if (chatAsInt(thread['id']) != threadId) continue;
            final last = thread['last_message'];
            if (last is Map) {
              final id = chatAsInt(last['id']);
              if (id != null && id > lastId) lastId = id;
            }
            break;
          }
        }
      } catch (e) {
        PushReplyTrace.log(
          'mark_read_threads_fail',
          threadId: threadId,
          source: source,
          detail: '$e',
        );
      }
    }

    if (lastId <= 0) {
      PushReplyTrace.log(
        'mark_read_fallback_messages',
        threadId: threadId,
        source: source,
      );
      await _markReadViaMessagesEndpoint(threadId: threadId, source: source);
      return;
    }

    try {
      await ChatLocalMutations.markThreadReadLocal(
        threadId,
        lastMessageId: lastId,
      );
    } catch (e) {
      PushReplyTrace.log(
        'mark_read_local_fail',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
    }

    final wsOk = await ChatWsMarkRead.tryMarkRead(
      threadId: threadId,
      lastMessageId: lastId,
    );
    if (wsOk) {
      PushReplyTrace.log(
        'mark_read_ws_ok',
        threadId: threadId,
        messageId: lastId,
        source: source,
      );
      return;
    }

    try {
      final client = ApiClient();
      client.dio.options = client.dio.options.copyWith(
        connectTimeout: markReadTimeout,
        receiveTimeout: markReadTimeout,
        sendTimeout: markReadTimeout,
      );
      final token = await client.tokenStorage.readAccess();
      if (token == null || token.isEmpty) {
        throw StateError('no access token');
      }
      await FamilyChatRepository(client)
          .markThreadRead(threadId, lastMessageId: lastId)
          .timeout(markReadTimeout);
      PushReplyTrace.log(
        'mark_read_http_ok',
        threadId: threadId,
        messageId: lastId,
        source: source,
      );
    } catch (e) {
      PushReplyTrace.log(
        'mark_read_http_fail',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
      try {
        await ChatOfflineOutbox.enqueueMarkRead(
          threadId: threadId,
          lastMessageId: lastId,
        );
      } catch (_) {}
    }
  }

  /// POST read через GET messages?mark_read=1, когда нет last_message_id.
  static Future<void> _markReadViaMessagesEndpoint({
    required int threadId,
    required String source,
  }) async {
    try {
      final client = ApiClient();
      client.dio.options = client.dio.options.copyWith(
        connectTimeout: markReadTimeout,
        receiveTimeout: markReadTimeout,
        sendTimeout: markReadTimeout,
      );
      final token = await client.tokenStorage.readAccess();
      if (token == null || token.isEmpty) {
        throw StateError('no access token');
      }
      final page = await FamilyChatRepository(client)
          .threadMessages(threadId, limit: 1, markRead: true)
          .timeout(markReadTimeout);
      var lastId = 0;
      if (page.messages.isNotEmpty) {
        lastId = chatAsInt(page.messages.last['id']) ?? 0;
      }
      if (lastId > 0) {
        await ChatLocalMutations.markThreadReadLocal(
          threadId,
          lastMessageId: lastId,
        );
      } else {
        await ChatLocalMutations.markThreadReadLocal(
          threadId,
          lastMessageId: 1,
        );
      }
      PushReplyTrace.log(
        'mark_read_messages_ok',
        threadId: threadId,
        messageId: lastId > 0 ? lastId : null,
        source: source,
      );
    } catch (e) {
      PushReplyTrace.log(
        'mark_read_messages_fail',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
      try {
        await ChatOfflineOutbox.enqueueMarkRead(
          threadId: threadId,
          lastMessageId: 1,
        );
      } catch (_) {}
    }
  }
}
