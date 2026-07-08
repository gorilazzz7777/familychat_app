import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/notifications/familychat_foreground_bridge.dart';
import '../../../core/push/push_message_handler.dart';
import '../../../core/push/push_navigation.dart';
import '../presentation/incoming_call_screen.dart';

/// Единая точка показа входящего звонка (WebSocket + push), без дублей.
class IncomingCallCoordinator {
  IncomingCallCoordinator._();

  static final IncomingCallCoordinator instance = IncomingCallCoordinator._();

  int? _activeCallId;
  bool _presenting = false;

  bool isPresentingCall(int callId) =>
      _presenting && _activeCallId == callId;

  void presentFromPushData(Map<String, dynamic> data) {
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
          : 'Family Chat',
    );
  }

  void present({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
  }) {
    if (_presenting && _activeCallId == callId) return;
    _activeCallId = callId;
    _presenting = true;
    familyChatScaffoldMessengerKey.currentState?.hideCurrentSnackBar();

    unawaited(_presentWhenReady(
      callId: callId,
      threadId: threadId,
      callerUserId: callerUserId,
      callerName: callerName,
    ));
  }

  Future<void> _presentWhenReady({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
  }) async {
    if (FamilyChatForegroundBridge.isAppInBackground()) {
      await FamilyChatForegroundBridge.bringToForegroundIfNeeded();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    final nav = familyChatNavigatorKey.currentState;
    if (nav == null) {
      pendingCallPushData = {
        'type': 'familychat_call',
        'session_id': '$callId',
        'thread_id': '$threadId',
        'caller_user_id': '$callerUserId',
        'caller_name': callerName,
      };
      return;
    }

    if (_presenting && _activeCallId == callId) {
      return;
    }

    try {
      await nav.push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          settings: RouteSettings(name: 'incoming_call_$callId'),
          builder: (_) => IncomingCallScreen(
            callId: callId,
            threadId: threadId,
            callerUserId: callerUserId,
            callerName: callerName,
          ),
        ),
      );
    } finally {
      if (_activeCallId == callId) {
        _activeCallId = null;
      }
      _presenting = false;
    }
  }

  void flushPendingIfAny() {
    final pending = pendingCallPushData;
    if (pending == null) return;
    pendingCallPushData = null;
    presentFromPushData(pending);
  }

  void markHandled(int callId) {
    if (_activeCallId == callId) {
      _activeCallId = null;
      _presenting = false;
    }
    familyChatScaffoldMessengerKey.currentState?.hideCurrentSnackBar();
  }
}
