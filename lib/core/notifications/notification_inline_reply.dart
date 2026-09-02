import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../local_db/chat_local_store.dart';
import '../network/api_client.dart';
import 'notification_mark_read.dart';
import 'push_reply_trace.dart';

/// Ответ из шторки уведомлений (как в Telegram).
abstract final class NotificationInlineReply {
  static const actionId = 'familychat_reply';
  static const iosCategoryId = 'familychat_message';
  static const sendTimeout = Duration(seconds: 20);

  static int _nextClientMsgId() => -DateTime.now().microsecondsSinceEpoch;

  static final Set<String> _sendInFlight = {};

  @pragma('vm:entry-point')
  static Future<bool> sendFromPayload({
    required Map<String, dynamic> data,
    required String rawText,
    String source = 'unknown',
  }) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      PushReplyTrace.log(
        'skip_empty',
        source: source,
        detail: 'body empty',
      );
      return false;
    }

    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    if (threadId == null) {
      PushReplyTrace.log(
        'skip_no_thread',
        source: source,
        extra: {'payloadKeys': data.keys.join(',')},
      );
      return false;
    }

    final dedupeKey = 'push_reply_${threadId}_${text.hashCode}';
    if (_sendInFlight.contains(dedupeKey)) {
      PushReplyTrace.log(
        'dedupe_inflight',
        threadId: threadId,
        source: source,
      );
      return true;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final handledAt = prefs.getInt('${dedupeKey}_at');
      if (handledAt != null &&
          DateTime.now().millisecondsSinceEpoch - handledAt < 120000) {
        PushReplyTrace.log(
          'dedupe_skip',
          threadId: threadId,
          source: source,
        );
        return true;
      }
    } catch (e) {
      PushReplyTrace.log(
        'dedupe_error',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
    }

    _sendInFlight.add(dedupeKey);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        '${dedupeKey}_at',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}

    final clientMsgId = _nextClientMsgId();
    PushReplyTrace.log(
      'http_start',
      threadId: threadId,
      source: source,
      extra: {
        'bodyLen': text.length,
        'clientMsgId': clientMsgId,
      },
    );

    try {
      final client = ApiClient();
      client.dio.options = client.dio.options.copyWith(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: sendTimeout,
        sendTimeout: sendTimeout,
      );
      client.sendDio.options = client.sendDio.options.copyWith(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: sendTimeout,
        sendTimeout: sendTimeout,
      );
      final token = await client.tokenStorage.readAccess();
      if (token == null || token.isEmpty) {
        PushReplyTrace.log(
          'http_no_token',
          threadId: threadId,
          source: source,
        );
        throw StateError('no access token');
      }

      final repo = FamilyChatRepository(client);
      final msg = await repo
          .sendThreadMessage(
            threadId,
            body: text,
            clientMsgId: clientMsgId,
          )
          .timeout(sendTimeout);
      final payload = Map<String, dynamic>.from(msg);
      payload['thread_id'] ??= threadId;
      final messageId = int.tryParse(payload['id']?.toString() ?? '');
      PushReplyTrace.log(
        'http_ok',
        threadId: threadId,
        messageId: messageId,
        source: source,
      );
      unawaited(_persistInBackground(threadId, payload, source: source));
      unawaited(
        NotificationMarkRead.markThreadReadFromPush(
          threadId: threadId,
          data: data,
          sentMessageId: messageId,
          source: source,
        ),
      );
      return true;
    } catch (e, st) {
      PushReplyTrace.log(
        'http_fail',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
      debugPrint('[NotificationInlineReply] send failed: $e\n$st');
      unawaited(
        NotificationMarkRead.markThreadReadFromPush(
          threadId: threadId,
          data: data,
          source: source,
        ),
      );
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('${dedupeKey}_at');
      } catch (_) {}
      return false;
    } finally {
      _sendInFlight.remove(dedupeKey);
    }
  }

  /// Отдельное соединение больше не открываем — второй NativeDatabase давал SQLITE_BUSY.
  static Future<void> _persistInBackground(
    int threadId,
    Map<String, dynamic> payload, {
    required String source,
  }) async {
    if (!ChatLocalStore.isSupported) return;
    try {
      await ChatLocalStore.instance
          .upsertMessages(threadId, [payload])
          .timeout(const Duration(seconds: 3));
      PushReplyTrace.log(
        'sqlite_ok',
        threadId: threadId,
        messageId: int.tryParse(payload['id']?.toString() ?? ''),
        source: source,
      );
    } catch (e) {
      PushReplyTrace.log(
        'sqlite_fail',
        threadId: threadId,
        source: source,
        detail: '$e',
      );
      debugPrint('[NotificationInlineReply] local upsert failed: $e');
    }
  }

}
