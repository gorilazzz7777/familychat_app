import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications/familychat_notifications.dart';
import '../../features/chat/data/incoming_call_coordinator.dart';
import '../../features/calendar/presentation/calendar_screen.dart';
import '../../features/chat/presentation/chat_conversation_screen.dart';

final familyChatNavigatorKey = GlobalKey<NavigatorState>();

/// Отложенный переход, если приложение ещё не готово (cold start по push).
Map<String, dynamic>? pendingChatPushData;
Map<String, dynamic>? pendingCalendarPushData;
Map<String, dynamic>? pendingCallPushData;
bool _chatPushRetryScheduled = false;

void flushPendingChatPush() {
  final data = pendingChatPushData;
  if (data != null) {
    pendingChatPushData = null;
    openChatFromPushData(data);
  }
  final calendar = pendingCalendarPushData;
  if (calendar != null) {
    pendingCalendarPushData = null;
    openCalendarFromPushData(calendar);
  }
  final call = pendingCallPushData;
  if (call != null) {
    pendingCallPushData = null;
    IncomingCallCoordinator.instance.presentFromPushData(call);
  }
}

bool _isChatPushData(Map<String, dynamic> data) {
  final type = data['type']?.toString() ?? '';
  if (type == 'familychat_chat') return true;
  // Some OEMs drop custom type but keep deeplink/thread_id.
  final deeplink = data['deeplink']?.toString() ?? '';
  final threadId = data['thread_id']?.toString() ?? '';
  return deeplink == 'chat' && threadId.isNotEmpty;
}

void openChatFromPushData(Map<String, dynamic> data) {
  final payload = Map<String, dynamic>.from(data);
  if (!_isChatPushData(payload)) return;

  final threadId = int.tryParse(payload['thread_id']?.toString() ?? '');
  if (threadId == null) return;

  unawaited(
    FamilyChatNotifications.clearChatNotifications(threadId: threadId),
  );

  void pushRoute(NavigatorState nav) {
    final title = payload['thread_title']?.toString().trim();
    final kind = payload['thread_kind']?.toString() ?? 'family';
    final peerUserId = int.tryParse(payload['peer_user_id']?.toString() ?? '');
    final messageId = int.tryParse(payload['message_id']?.toString() ?? '');

    nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatConversationScreen(
          threadId: threadId,
          title: title != null && title.isNotEmpty ? title : 'Чат',
          kind: kind,
          peerUserId: peerUserId,
          initialMessageId: messageId,
        ),
      ),
    );
  }

  final nav = familyChatNavigatorKey.currentState;
  if (nav == null) {
    pendingChatPushData = payload;
    // Retry shortly — share/bootstrap may mount navigator a tick later.
    if (!_chatPushRetryScheduled) {
      _chatPushRetryScheduled = true;
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        _chatPushRetryScheduled = false;
        if (pendingChatPushData == null) return;
        flushPendingChatPush();
      });
    }
    return;
  }

  // Defer to next frame so we don't push during build/transition (e.g. after share).
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final current = familyChatNavigatorKey.currentState;
    if (current == null) {
      pendingChatPushData = payload;
      return;
    }
    pushRoute(current);
  });
}

void openCalendarFromPushData(Map<String, dynamic> data) {
  if (data['type']?.toString() != 'familychat_calendar_reminder') return;

  final nav = familyChatNavigatorKey.currentState;
  if (nav == null) {
    pendingCalendarPushData = Map<String, dynamic>.from(data);
    return;
  }

  nav.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const CalendarScreen(),
    ),
  );
}

void openCallFromPushData(Map<String, dynamic> data) {
  IncomingCallCoordinator.instance.presentFromPushData(data);
}
