import 'dart:async';

import 'package:flutter/material.dart';

import '../../contract/chat_call_repository.dart';
import '../../realtime/gorila_chat_realtime.dart';
import 'incoming_call_screen.dart';

/// Single entry for incoming calls (WS + push), without duplicates.
class IncomingCallCoordinator {
  IncomingCallCoordinator._();
  static final IncomingCallCoordinator instance = IncomingCallCoordinator._();

  int? _activeCallId;
  bool _presenting = false;

  GlobalKey<NavigatorState>? navigatorKey;
  ChatCallRepository? callRepository;
  GorilaChatRealtime? realtime;
  int? myUserId;
  String pushType = 'teamcoach_call';

  Map<String, dynamic>? pendingCallPushData;

  bool isPresentingCall(int callId) => _presenting && _activeCallId == callId;

  void configure({
    required GlobalKey<NavigatorState> navigatorKey,
    required ChatCallRepository callRepository,
    required GorilaChatRealtime realtime,
    int? myUserId,
    String pushType = 'teamcoach_call',
  }) {
    this.navigatorKey = navigatorKey;
    this.callRepository = callRepository;
    this.realtime = realtime;
    this.myUserId = myUserId;
    this.pushType = pushType;
  }

  void presentFromPushData(Map<String, dynamic> data) {
    if (data['type']?.toString() != pushType) return;
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
          : 'Звонок',
    );
  }

  void presentFromRealtime(Map<String, dynamic> event) {
    if (event['event']?.toString() != 'chat_call_incoming') return;
    final callId = int.tryParse(event['session_id']?.toString() ?? '');
    final threadId = int.tryParse(event['thread_id']?.toString() ?? '');
    if (callId == null || threadId == null) return;
    present(
      callId: callId,
      threadId: threadId,
      callerUserId: int.tryParse(event['caller_user_id']?.toString() ?? '') ?? 0,
      callerName: event['caller_name']?.toString() ?? 'Звонок',
    );
  }

  void present({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
    String? callerAvatarUrl,
  }) {
    if (_presenting && _activeCallId == callId) return;
    _activeCallId = callId;
    unawaited(
      _presentWhenReady(
        callId: callId,
        threadId: threadId,
        callerUserId: callerUserId,
        callerName: callerName,
        callerAvatarUrl: callerAvatarUrl,
      ),
    );
  }

  void markHandled(int callId) {
    if (_activeCallId == callId) {
      _presenting = false;
      _activeCallId = null;
    }
  }

  void flushPendingIfAny() {
    final data = pendingCallPushData;
    if (data == null) return;
    pendingCallPushData = null;
    presentFromPushData(data);
  }

  Future<void> _presentWhenReady({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
    String? callerAvatarUrl,
  }) async {
    if (_presenting) return;
    final navKey = navigatorKey;
    final repo = callRepository;
    final rt = realtime;
    if (navKey == null || repo == null || rt == null) {
      pendingCallPushData = {
        'type': pushType,
        'session_id': '$callId',
        'thread_id': '$threadId',
        'caller_user_id': '$callerUserId',
        'caller_name': callerName,
      };
      return;
    }

    NavigatorState? nav;
    for (var i = 0; i < 40; i++) {
      nav = navKey.currentState;
      if (nav != null && nav.mounted) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (nav == null || !nav.mounted) {
      pendingCallPushData = {
        'type': pushType,
        'session_id': '$callId',
        'thread_id': '$threadId',
        'caller_user_id': '$callerUserId',
        'caller_name': callerName,
      };
      return;
    }

    _presenting = true;
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
            callerAvatarUrl: callerAvatarUrl,
            callRepository: repo,
            realtime: rt,
            myUserId: myUserId,
            onHandled: () => markHandled(callId),
          ),
        ),
      );
    } finally {
      markHandled(callId);
    }
  }
}
