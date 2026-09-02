import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../network/api_client.dart';
import 'familychat_notifications.dart';

/// «Принять» / «Отклонить» на пуше входящего звонка.
abstract final class NotificationCallActions {
  static const acceptActionId = 'familychat_call_accept';
  static const declineActionId = 'familychat_call_decline';
  static const iosCategoryId = 'familychat_call';

  @pragma('vm:entry-point')
  static Future<void> declineFromPayload({
    required Map<String, dynamic> data,
    String source = 'unknown',
  }) async {
    final callId = int.tryParse(data['session_id']?.toString() ?? '');
    if (callId == null) return;
    try {
      final repo = FamilyChatRepository(ApiClient());
      await repo.callAction(callId, 'decline');
    } catch (e, st) {
      debugPrint('call decline from $source failed: $e\n$st');
    } finally {
      await FamilyChatNotifications.cancelCallNotification(callId);
    }
  }
}
