import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../local_db/chat_local_store.dart';
import '../network/api_client.dart';

/// Ответ из шторки уведомлений (как в Telegram).
abstract final class NotificationInlineReply {
  static const actionId = 'familychat_reply';
  static const iosCategoryId = 'familychat_message';
  static const sendTimeout = Duration(seconds: 20);

  static Future<bool> sendFromPayload({
    required Map<String, dynamic> data,
    required String rawText,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty) return false;

    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    if (threadId == null) return false;

    final dedupeKey =
        'push_reply_${threadId}_${text.hashCode}_${DateTime.now().millisecondsSinceEpoch ~/ 8000}';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(dedupeKey) == true) return true;
      await prefs.setBool(dedupeKey, true);
    } catch (_) {}

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
      final repo = FamilyChatRepository(client);
      final msg = await repo
          .sendThreadMessage(
            threadId,
            body: text,
            clientMsgId: DateTime.now().microsecondsSinceEpoch,
          )
          .timeout(sendTimeout);
      final payload = Map<String, dynamic>.from(msg);
      payload['thread_id'] ??= threadId;
      unawaited(_persistInBackground(threadId, payload));
      return true;
    } catch (e, st) {
      debugPrint('[NotificationInlineReply] send failed: $e\n$st');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(dedupeKey);
      } catch (_) {}
      return false;
    }
  }

  /// Отдельное соединение больше не открываем — второй NativeDatabase давал SQLITE_BUSY.
  static Future<void> _persistInBackground(
    int threadId,
    Map<String, dynamic> payload,
  ) async {
    if (!ChatLocalStore.isSupported) return;
    try {
      await ChatLocalStore.instance
          .upsertMessages(threadId, [payload])
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('[NotificationInlineReply] local upsert failed: $e');
    }
  }
}
