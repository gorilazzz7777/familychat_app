import 'package:flutter/material.dart';

import '../../features/chat/data/incoming_call_coordinator.dart';
import '../../features/calendar/presentation/calendar_screen.dart';
import '../../features/chat/presentation/chat_conversation_screen.dart';

final familyChatNavigatorKey = GlobalKey<NavigatorState>();

/// Отложенный переход, если приложение ещё не готово (cold start по push).
Map<String, dynamic>? pendingChatPushData;
Map<String, dynamic>? pendingCalendarPushData;
Map<String, dynamic>? pendingCallPushData;

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

void openChatFromPushData(Map<String, dynamic> data) {
  if (data['type']?.toString() != 'familychat_chat') return;

  final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
  if (threadId == null) return;

  final nav = familyChatNavigatorKey.currentState;
  if (nav == null) {
    pendingChatPushData = Map<String, dynamic>.from(data);
    return;
  }

  final title = data['thread_title']?.toString().trim();
  final kind = data['thread_kind']?.toString() ?? 'family';
  final peerUserId = int.tryParse(data['peer_user_id']?.toString() ?? '');
  final messageId = int.tryParse(data['message_id']?.toString() ?? '');

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
