import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../notifications/familychat_notifications.dart';
import '../notifications/familychat_foreground_bridge.dart';
import '../../features/chat/data/active_chat_context.dart';
import '../../features/chat/data/familychat_realtime.dart';
import '../../features/chat/data/chat_sync_service.dart';
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
  final isForeground = FamilyChatForegroundBridge.isAppInForeground();

  if (type == 'familychat_chat' ||
      (data['deeplink']?.toString() == 'chat' &&
          (data['thread_id']?.toString() ?? '').isNotEmpty)) {
    final payload = Map<String, dynamic>.from(data);
    final rawType = payload['type']?.toString() ?? '';
    if (rawType.isEmpty) {
      payload['type'] = 'familychat_chat';
    }
    final threadId = int.tryParse(payload['thread_id']?.toString() ?? '');
    final messageId = int.tryParse(payload['message_id']?.toString() ?? '');

    FamilyChatRealtime.instance.emitSyntheticEvent({
      'event': 'chat_refresh',
      'thread_id': threadId,
      'message_id': messageId,
    });
    if (threadId != null && ChatSyncService.isSupported) {
      unawaited(ChatSyncService.instance.syncThreadFromPush(threadId));
    }

    if (openedFromTap) {
      openChatFromPushData(payload);
      return;
    }

    if (threadId != null &&
        ActiveChatContext.instance.isViewingThread(threadId)) {
      return;
    }

    if (isForeground) return;
  }

  if (type == 'familychat_calendar_reminder') {
    if (openedFromTap) {
      openCalendarFromPushData(data);
      return;
    }
    if (isForeground) return;
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
  if (isForeground) return;

  final notification = message.notification;
  if (notification == null) {
    final title = data['title']?.toString().trim();
    final body = data['body']?.toString().trim();
    if (title == null && body == null) return;
    unawaited(
      FamilyChatNotifications.showForegroundPush(
        title: title != null && title.isNotEmpty ? title : 'Family Chat',
        body: body != null && body.isNotEmpty ? body : 'Новое уведомление',
        data: Map<String, dynamic>.from(data),
      ),
    );
    return;
  }

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
