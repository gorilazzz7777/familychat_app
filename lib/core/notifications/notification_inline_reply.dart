import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/chat/data/familychat_realtime.dart';
import '../../features/familychat/data/familychat_repository.dart';
import '../local_db/chat_local_store.dart';
import '../network/api_client.dart';

/// Ответ из шторки уведомлений (как в Telegram).
abstract final class NotificationInlineReply {
  static const actionId = 'familychat_reply';
  static const iosCategoryId = 'familychat_message';

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
      final repo = FamilyChatRepository(ApiClient());
      final msg = await repo.sendThreadMessage(threadId, body: text);
      final payload = Map<String, dynamic>.from(msg);
      payload['thread_id'] ??= threadId;
      if (ChatLocalStore.isSupported) {
        try {
          await ChatLocalStore.instance.upsertMessages(threadId, [payload]);
        } catch (e) {
          debugPrint('[NotificationInlineReply] local upsert failed: $e');
        }
      }
      try {
        FamilyChatRealtime.instance.emitSyntheticEvent({
          'event': 'chat_refresh',
          'thread_id': threadId,
          'message_id': payload['id'],
        });
      } catch (_) {}
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
}
