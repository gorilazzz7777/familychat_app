import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../call/callkit_incoming_service.dart';
import '../diagnostics/app_session_diagnostics.dart';
import '../notifications/familychat_notifications.dart';
import '../notifications/familychat_foreground_bridge.dart';
import '../../features/chat/data/familychat_realtime.dart';
import '../../features/chat/data/chat_sync_service.dart';
import '../../features/chat/data/hub_first_paint_snapshot.dart';
import '../../features/chat/data/incoming_call_coordinator.dart';
import '../../features/telegram_tdlib/telegram_tdlib_push.dart';
import '../../features/telegram_tdlib/telegram_tdlib_service.dart';
import 'push_navigation.dart';
import 'web_push_bridge.dart';

/// Показать push в UI, когда приложение на переднем плане (Android не показывает системный баннер).
final familyChatScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void handleFamilyChatRemoteMessage(
  RemoteMessage message, {
  bool openedFromTap = false,
}) {
  final data = message.data;
  final type = data['type']?.toString() ?? '';
  final isForeground = FamilyChatForegroundBridge.isAppInForeground();
  AppSessionDiagnostics.instance.push(
    openedFromTap ? 'opened' : 'received',
    {
      'type': type.isEmpty ? null : type,
      'tg': isTelegramRemoteMessage(message),
      'fg': isForeground,
      'threadId': int.tryParse(data['thread_id']?.toString() ?? ''),
    },
  );

  if (isTelegramRemoteMessage(message)) {
    if (openedFromTap) {
      // Encrypted TG pushes have no FC chat_id; TDLib will raise local banner.
      return;
    }
    unawaited(
      TelegramTdlibService.instance.processPushNotificationPayload(
        buildTdlibProcessPushPayload(message),
      ),
    );
    _patchHubSnapshotFromTgPush(Map<String, dynamic>.from(data), message);
    return;
  }

  if (type == kTdlibPushType) {
    if (openedFromTap) {
      openTdlibChatFromPushData(Map<String, dynamic>.from(data));
      return;
    }
    return;
  }

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
    unawaited(
      HubFirstPaintSnapshot.patchRow(
        threadId: threadId,
        title: payload['thread_title']?.toString() ??
            payload['title']?.toString() ??
            message.notification?.title,
        lastBody: payload['body']?.toString() ?? message.notification?.body,
        lastCreatedAt: DateTime.now().toUtc().toIso8601String(),
        bumpUnread: true,
      ),
    );

    if (openedFromTap) {
      openChatFromPushData(payload);
      return;
    }

    if (threadId != null &&
        FamilyChatForegroundBridge.isActivelyViewingThread(threadId)) {
      return;
    }

    unawaited(_showChatPushNotification(message, payload));
    return;
  }

  if (type == 'familychat_calendar_reminder') {
    if (openedFromTap) {
      openCalendarFromPushData(data);
      return;
    }
    if (isForeground) return;
  }

  if (type == 'familychat_feed_photos' ||
      data['deeplink']?.toString() == 'feed') {
    if (openedFromTap) {
      openFeedFromPushData(data);
      return;
    }
    if (isForeground) return;
  }

  if (type == 'familychat_call_stop') {
    final callId = int.tryParse(data['session_id']?.toString() ?? '');
    if (callId != null) {
      unawaited(FamilyChatNotifications.cancelCallNotification(callId));
      unawaited(CallKitIncomingService.endCall(callId));
      unawaited(stopServiceWorkerCallRing(callId));
      IncomingCallCoordinator.instance.markHandled(callId);
    }
    return;
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
        title: title != null && title.isNotEmpty ? title : 'Family Space',
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
      title: title != null && title.isNotEmpty ? title : 'Family Space',
      body: body != null && body.isNotEmpty ? body : 'Новое уведомление',
      data: pushData,
    ),
  );
}

Future<void> _showChatPushNotification(
  RemoteMessage message,
  Map<String, dynamic> payload,
) async {
  final threadId = int.tryParse(payload['thread_id']?.toString() ?? '');
  if (threadId != null && ChatSyncService.isSupported) {
    try {
      await ChatSyncService.instance.syncThreadFromPush(threadId);
    } catch (e, st) {
      debugPrint('chat push sync before notify failed: $e\n$st');
    }
  }

  final notification = message.notification;
  final title = notification?.title?.trim() ??
      payload['title']?.toString().trim();
  final body = notification?.body?.trim() ?? payload['body']?.toString().trim();

  await FamilyChatNotifications.showForegroundPush(
    title: title != null && title.isNotEmpty ? title : 'Family Space',
    body: body != null && body.isNotEmpty ? body : 'Новое сообщение',
    data: payload,
    enrichChatPreviewFromDatabase: true,
  );
}

void _patchHubSnapshotFromTgPush(
  Map<String, dynamic> data,
  RemoteMessage message,
) {
  final chatId = int.tryParse(data['chat_id']?.toString() ?? '') ??
      int.tryParse(data['tg_chat_id']?.toString() ?? '') ??
      int.tryParse(data['dialog_id']?.toString() ?? '');
  if (chatId == null || chatId == 0) return;
  final title = data['title']?.toString() ?? message.notification?.title;
  final body = data['body']?.toString() ??
      data['message']?.toString() ??
      message.notification?.body;
  unawaited(
    HubFirstPaintSnapshot.patchRow(
      tdlibChatId: chatId,
      title: title,
      lastBody: body,
      lastCreatedAt: DateTime.now().toUtc().toIso8601String(),
      bumpUnread: true,
    ),
  );
}
