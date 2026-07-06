import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../../features/chat/data/familychat_realtime.dart';

/// Показать push в UI, когда приложение на переднем плане (Android не показывает системный баннер).
final familyChatScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void handleFamilyChatRemoteMessage(RemoteMessage message) {
  final data = message.data;
  final type = data['type']?.toString() ?? '';
  if (type == 'familychat_chat') {
    FamilyChatRealtime.instance.emitSyntheticEvent({
      'type': 'chat_message',
      'thread_id': int.tryParse(data['thread_id']?.toString() ?? ''),
    });
  }

  final notification = message.notification;
  if (notification == null) return;

  final title = notification.title?.trim();
  final body = notification.body?.trim();
  if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) return;

  familyChatScaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(
        title != null && title.isNotEmpty
            ? (body != null && body.isNotEmpty ? '$title\n$body' : title)
            : body!,
      ),
      duration: const Duration(seconds: 4),
    ),
  );
}
