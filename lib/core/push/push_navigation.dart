import 'package:flutter/material.dart';

import '../../features/chat/presentation/chat_conversation_screen.dart';

final familyChatNavigatorKey = GlobalKey<NavigatorState>();

/// Отложенный переход, если приложение ещё не готово (cold start по push).
Map<String, dynamic>? pendingChatPushData;

void flushPendingChatPush() {
  final data = pendingChatPushData;
  if (data == null) return;
  pendingChatPushData = null;
  openChatFromPushData(data);
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
