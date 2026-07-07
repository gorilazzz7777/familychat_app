import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../../features/chat/data/active_chat_context.dart';
import '../../features/chat/data/familychat_realtime.dart';
import 'push_navigation.dart';

/// Показать push в UI, когда приложение на переднем плане (Android не показывает системный баннер).
final familyChatScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void handleFamilyChatRemoteMessage(
  RemoteMessage message, {
  bool openedFromTap = false,
}) {
  final data = message.data;
  final type = data['type']?.toString() ?? '';

  if (type == 'familychat_chat') {
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    final messageId = int.tryParse(data['message_id']?.toString() ?? '');

    FamilyChatRealtime.instance.emitSyntheticEvent({
      'event': 'chat_refresh',
      'thread_id': threadId,
      'message_id': messageId,
    });

    if (threadId != null && ActiveChatContext.instance.isViewingThread(threadId)) {
      return;
    }

    if (openedFromTap) {
      openChatFromPushData(data);
      return;
    }
  }

  if (type == 'familychat_calendar_reminder') {
    if (openedFromTap) {
      openCalendarFromPushData(data);
      return;
    }
  }

  if (openedFromTap) return;

  final notification = message.notification;
  if (notification == null) return;

  final title = notification.title?.trim();
  final body = notification.body?.trim();
  if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) return;

  final pushData = Map<String, dynamic>.from(data);
  familyChatScaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(
        title != null && title.isNotEmpty
            ? (body != null && body.isNotEmpty ? '$title\n$body' : title)
            : body!,
      ),
      duration: const Duration(seconds: 5),
      action: type == 'familychat_chat'
          ? SnackBarAction(
              label: 'Открыть',
              onPressed: () => openChatFromPushData(pushData),
            )
          : type == 'familychat_calendar_reminder'
              ? SnackBarAction(
                  label: 'Календарь',
                  onPressed: () => openCalendarFromPushData(pushData),
                )
              : null,
    ),
  );
}
