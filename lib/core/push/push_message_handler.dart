import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../notifications/familychat_notifications.dart';
import '../../features/chat/data/active_chat_context.dart';
import '../../features/chat/data/familychat_realtime.dart';
import '../../features/chat/data/incoming_call_coordinator.dart';
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

    if (threadId != null &&
        ActiveChatContext.instance.isViewingThread(threadId)) {
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

  if (type == 'familychat_call') {
    if (openedFromTap) {
      IncomingCallCoordinator.instance.presentFromPushData(data);
      return;
    }
    IncomingCallCoordinator.instance.presentFromPushData(data);
    return;
  }

  if (openedFromTap) return;

  final notification = message.notification;
  if (notification == null) return;

  final title = notification.title?.trim();
  final body = notification.body?.trim();
  if ((title == null || title.isEmpty) && (body == null || body.isEmpty)) {
    return;
  }

  final pushData = Map<String, dynamic>.from(data);
  unawaited(
    FamilyChatNotifications.showForegroundPush(
      title: title != null && title.isNotEmpty ? title : 'Family Chat',
      body: body != null && body.isNotEmpty ? body : 'Новое уведомление',
      data: pushData,
    ),
  );
}
