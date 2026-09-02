import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:gorila_chat/gorila_chat.dart' show parseCallIsVideo;

import '../../../core/call/call_lock_screen.dart';
import '../../../core/call/callkit_incoming_service.dart';
import '../../../core/notifications/familychat_foreground_bridge.dart';
import '../../../core/notifications/familychat_notifications.dart';
import '../../../core/push/push_message_handler.dart';
import '../../../core/push/push_navigation.dart';
import '../../../core/push/web_push_bridge.dart';
import '../presentation/incoming_call_screen.dart';

/// Единая точка показа входящего звонка (WebSocket + push), без дублей.
class IncomingCallCoordinator {
  IncomingCallCoordinator._();

  static final IncomingCallCoordinator instance = IncomingCallCoordinator._();

  int? _activeCallId;
  bool _presenting = false;

  bool isPresentingCall(int callId) =>
      _presenting && _activeCallId == callId;

  static bool parseIsVideo(Object? raw) => parseCallIsVideo(raw);

  void presentFromPushData(Map<String, dynamic> data) {
    if (data['type']?.toString() == 'familychat_call_accepted') {
      openAcceptedCallFromPushData(data);
      return;
    }
    if (data['type']?.toString() != 'familychat_call') return;
    final callId = int.tryParse(data['session_id']?.toString() ?? '');
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    if (callId == null || threadId == null) return;
    final callerUserId =
        int.tryParse(data['caller_user_id']?.toString() ?? '') ?? 0;
    final callerName = data['caller_name']?.toString().trim();
    present(
      callId: callId,
      threadId: threadId,
      callerUserId: callerUserId,
      callerName: callerName != null && callerName.isNotEmpty
          ? callerName
          : 'Family Space',
      isVideo: parseIsVideo(data['is_video']),
    );
  }

  void present({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
    bool isVideo = false,
  }) {
    if (_presenting && _activeCallId == callId) return;
    _activeCallId = callId;
    familyChatScaffoldMessengerKey.currentState?.hideCurrentSnackBar();
    unawaited(FamilyChatNotifications.cancelCallNotification(callId));
    unawaited(stopServiceWorkerCallRing(callId));

    if (CallKitIncomingService.isSupported) {
      _presenting = true;
      unawaited(CallKitIncomingService.showIncomingCall(
        callId: callId,
        threadId: threadId,
        callerUserId: callerUserId,
        callerName: callerName,
        isVideo: isVideo,
      ));
      return;
    }

    unawaited(_presentWhenReady(
      callId: callId,
      threadId: threadId,
      callerUserId: callerUserId,
      callerName: callerName,
      isVideo: isVideo,
    ));
  }

  Future<void> _presentWhenReady({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
    required bool isVideo,
  }) async {
    if (_presenting) return;
    _presenting = true;
    await CallLockScreen.acquire();
    try {
      if (FamilyChatForegroundBridge.isAppInBackground()) {
        await FamilyChatForegroundBridge.bringToForegroundIfNeeded(forCall: true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final nav = await _waitForNavigator();
      if (nav == null) {
        pendingCallPushData = {
          'type': 'familychat_call',
          'session_id': '$callId',
          'thread_id': '$threadId',
          'caller_user_id': '$callerUserId',
          'caller_name': callerName,
          'is_video': isVideo ? '1' : '0',
        };
        return;
      }

      if (!nav.mounted) return;

      await nav.push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          settings: RouteSettings(name: 'incoming_call_$callId'),
          builder: (_) => IncomingCallScreen(
            callId: callId,
            threadId: threadId,
            callerUserId: callerUserId,
            callerName: callerName,
            isVideo: isVideo,
          ),
        ),
      );
    } finally {
      if (_activeCallId == callId) {
        _activeCallId = null;
      }
      _presenting = false;
      unawaited(CallLockScreen.release());
    }
  }

  Future<NavigatorState?> _waitForNavigator() async {
    for (var attempt = 0; attempt < 30; attempt++) {
      final nav = familyChatNavigatorKey.currentState;
      if (nav != null) return nav;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return familyChatNavigatorKey.currentState;
  }

  void flushPendingIfAny() {
    final pending = pendingCallPushData;
    if (pending == null) return;
    pendingCallPushData = null;
    presentFromPushData(pending);
  }

  void noteCallAccepted(int callId) {
    if (_activeCallId == callId) {
      _activeCallId = null;
      _presenting = false;
    }
    familyChatScaffoldMessengerKey.currentState?.hideCurrentSnackBar();
    unawaited(FamilyChatNotifications.cancelCallNotification(callId));
    unawaited(stopServiceWorkerCallRing(callId));
  }

  void markHandled(int callId) {
    if (_activeCallId == callId) {
      _activeCallId = null;
      _presenting = false;
    }
    familyChatScaffoldMessengerKey.currentState?.hideCurrentSnackBar();
    unawaited(FamilyChatNotifications.cancelCallNotification(callId));
    unawaited(stopServiceWorkerCallRing(callId));
    unawaited(CallKitIncomingService.endCall(callId));
  }
}
