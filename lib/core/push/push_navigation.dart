import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications/familychat_notifications.dart';
import '../../features/chat/presentation/chat_call_screen.dart';
import '../../features/chat/data/active_chat_context.dart';
import '../../features/chat/data/chat_local_reads.dart';
import '../../features/chat/data/incoming_call_coordinator.dart';
import '../../features/calendar/presentation/calendar_screen.dart';
import '../../features/chat/presentation/chat_conversation_screen.dart';

final familyChatNavigatorKey = GlobalKey<NavigatorState>();

/// Отложенный переход, если приложение ещё не готово (cold start по push).
Map<String, dynamic>? pendingChatPushData;
Map<String, dynamic>? pendingCalendarPushData;
Map<String, dynamic>? pendingCallPushData;
Map<String, dynamic>? pendingFeedPushData;
VoidCallback? onOpenFeedFromPush;
bool _chatPushRetryScheduled = false;
int? _openingThreadId;
DateTime? _openingThreadAt;

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
  final feed = pendingFeedPushData;
  if (feed != null) {
    pendingFeedPushData = null;
    openFeedFromPushData(feed);
  }
}

Map<String, dynamic> _unwrapPushData(Map<String, dynamic> data) {
  final nested = data['FCM_MSG'];
  if (nested is! Map) return data;
  final inner = nested['data'];
  if (inner is! Map) return data;
  return {
    ...inner.map((key, value) => MapEntry(key.toString(), value)),
    ...data,
  };
}

bool _isChatPushData(Map<String, dynamic> data) {
  final type = data['type']?.toString() ?? '';
  if (type == 'familychat_call' ||
      type == 'familychat_calendar_reminder' ||
      type == 'familychat_feed_photos') {
    return false;
  }
  final threadId = data['thread_id']?.toString() ?? '';
  if (threadId.isEmpty) return false;
  if (type == 'familychat_chat') return true;
  final deeplink = data['deeplink']?.toString() ?? '';
  if (deeplink == 'feed' || deeplink == 'calendar') return false;
  return deeplink == 'chat' || type.isEmpty;
}

void openChatFromPushData(Map<String, dynamic> data) {
  final payload = _unwrapPushData(Map<String, dynamic>.from(data));
  if (!_isChatPushData(payload)) return;

  final threadId = int.tryParse(payload['thread_id']?.toString() ?? '');
  if (threadId == null) return;
  payload['type'] = 'familychat_chat';

  final now = DateTime.now();
  if (_openingThreadId == threadId &&
      _openingThreadAt != null &&
      now.difference(_openingThreadAt!) < const Duration(milliseconds: 800)) {
    return;
  }
  _openingThreadId = threadId;
  _openingThreadAt = now;

  unawaited(
    FamilyChatNotifications.clearChatNotifications(threadId: threadId),
  );

  if (ActiveChatContext.instance.isViewingThread(threadId)) return;

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
    unawaited(_pushChatFromPayload(payload, threadId));
  });
}

Future<void> _pushChatFromPayload(
  Map<String, dynamic> payload,
  int threadId,
) async {
  if (ActiveChatContext.instance.isViewingThread(threadId)) return;

  final hydrated = await _hydrateChatPushPayload(payload, threadId);
  final current = familyChatNavigatorKey.currentState;
  if (current == null) {
    pendingChatPushData = hydrated;
    return;
  }
  if (ActiveChatContext.instance.isViewingThread(threadId)) return;

  if (current.canPop()) {
    current.popUntil((route) => route.isFirst);
  }

  final title = hydrated['thread_title']?.toString().trim();
  final kind = hydrated['thread_kind']?.toString().trim();
  final peerUserId = int.tryParse(hydrated['peer_user_id']?.toString() ?? '');
  final messageId = int.tryParse(hydrated['message_id']?.toString() ?? '');

  current.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ChatConversationScreen(
        threadId: threadId,
        title: title != null && title.isNotEmpty ? title : 'Чат',
        kind: (kind != null && kind.isNotEmpty) ? kind : 'family',
        peerUserId: peerUserId,
        initialMessageId: messageId,
        expectedLastMessageId: messageId,
      ),
    ),
  );
}

Future<Map<String, dynamic>> _hydrateChatPushPayload(
  Map<String, dynamic> payload,
  int threadId,
) async {
  final hasTitle =
      (payload['thread_title']?.toString().trim() ?? '').isNotEmpty;
  final hasKind = (payload['thread_kind']?.toString().trim() ?? '').isNotEmpty;
  if (hasTitle && hasKind) return payload;
  try {
    final thread = await ChatLocalReads.threadById(threadId);
    if (thread == null) return payload;
    return {
      ...payload,
      if (!hasTitle)
        'thread_title': thread['custom_title'] ??
            thread['title'] ??
            thread['default_title'] ??
            payload['thread_title'],
      if (!hasKind) 'thread_kind': thread['kind'] ?? payload['thread_kind'],
      if (payload['peer_user_id'] == null ||
          payload['peer_user_id'].toString().isEmpty)
        'peer_user_id': thread['peer_user_id'],
    };
  } catch (_) {}
  return payload;
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

bool _isFeedPushData(Map<String, dynamic> data) {
  final type = data['type']?.toString() ?? '';
  final deeplink = data['deeplink']?.toString() ?? '';
  return type == 'familychat_feed_photos' || deeplink == 'feed';
}

void openFeedFromPushData(Map<String, dynamic> data) {
  final payload = _unwrapPushData(Map<String, dynamic>.from(data));
  if (!_isFeedPushData(payload)) return;

  final nav = familyChatNavigatorKey.currentState;
  if (nav == null) {
    pendingFeedPushData = payload;
    return;
  }
  if (nav.canPop()) {
    nav.popUntil((route) => route.isFirst);
  }
  final openFeed = onOpenFeedFromPush;
  if (openFeed == null) {
    pendingFeedPushData = payload;
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) => openFeed());
}

void openCallFromPushData(Map<String, dynamic> data) {
  IncomingCallCoordinator.instance.presentFromPushData(data);
}

void openAcceptedCallFromPushData(Map<String, dynamic> data) {
  final callId = int.tryParse(data['session_id']?.toString() ?? '');
  final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
  if (callId == null || threadId == null) return;
  IncomingCallCoordinator.instance.noteCallAccepted(callId);
  final callerName = data['caller_name']?.toString().trim();
  final isVideo = data['is_video']?.toString() == '1';

  final nav = familyChatNavigatorKey.currentState;
  if (nav == null) {
    pendingCallPushData = {
      'type': 'familychat_call_accepted',
      'session_id': '$callId',
      'thread_id': '$threadId',
      'caller_name': callerName ?? 'Family Space',
      'is_video': isVideo ? '1' : '0',
    };
    if (!_chatPushRetryScheduled) {
      _chatPushRetryScheduled = true;
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        _chatPushRetryScheduled = false;
        flushPendingChatPush();
      });
    }
    return;
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!nav.mounted) return;
    nav.push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        settings: RouteSettings(name: 'call_$callId'),
        builder: (_) => ChatCallScreen(
          threadId: threadId,
          title: callerName != null && callerName.isNotEmpty
              ? callerName
              : 'Family Space',
          callId: callId,
          isCaller: false,
          isVideo: isVideo,
        ),
      ),
    );
  });
}
