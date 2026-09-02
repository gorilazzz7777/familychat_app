import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../network/api_client.dart';
import '../notifications/familychat_foreground_bridge.dart';
import '../notifications/notification_call_actions.dart';
import '../push/web_push_bridge.dart';

typedef CallKitAcceptedHandler = Future<void> Function(Map<String, dynamic> extra, int callId);
typedef CallKitEndedHandler = Future<void> Function(int callId);

/// Системный экран входящего звонка (CallKit / ConnectionService).
abstract final class CallKitIncomingService {
  CallKitIncomingService._();

  static CallKitAcceptedHandler? onAccepted;
  static CallKitEndedHandler? onEnded;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static StreamSubscription<CallEvent?>? _eventSub;
  static bool _initialized = false;
  static final Set<int> _shownCallIds = {};

  static String callUuid(int callId) => 'familychat_call_$callId';

  static int? callIdFromUuid(String? uuid) {
    if (uuid == null || uuid.isEmpty) return null;
    const prefix = 'familychat_call_';
    if (!uuid.startsWith(prefix)) return int.tryParse(uuid);
    return int.tryParse(uuid.substring(prefix.length));
  }

  static Map<String, dynamic> _extraFromPushData(Map<String, dynamic> data) {
    return {
      'type': 'familychat_call',
      'session_id': data['session_id']?.toString() ?? '',
      'thread_id': data['thread_id']?.toString() ?? '',
      'caller_user_id': data['caller_user_id']?.toString() ?? '',
      'caller_name': data['caller_name']?.toString() ?? '',
      'is_video': data['is_video']?.toString() ?? '0',
    };
  }

  static Map<String, dynamic>? _extraFromEventBody(Map<String, dynamic>? body) {
    if (body == null) return null;
    final extra = body['extra'];
    if (extra is Map) {
      return extra.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  static Future<void> initialize() async {
    if (!isSupported || _initialized) return;
    _initialized = true;

    onEnded ??= (callId) async {
      unawaited(stopServiceWorkerCallRing(callId));
      await endCall(callId);
    };
    onAccepted ??= (extra, callId) async {
      try {
        final repo = FamilyChatRepository(ApiClient());
        await repo.callAction(callId, 'accept');
      } catch (e, st) {
        debugPrint('[CallKit] background accept failed: $e\n$st');
      }
      try {
        await FlutterCallkitIncoming.setCallConnected(callUuid(callId));
      } catch (_) {}
    };

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final canFullScreen = await FlutterCallkitIncoming.canUseFullScreenIntent();
        if (canFullScreen != true) {
          await FlutterCallkitIncoming.requestFullIntentPermission();
        }
      } catch (e) {
        debugPrint('[CallKit] full intent permission: $e');
      }
    }

    _eventSub ??= FlutterCallkitIncoming.onEvent.listen(_onCallEvent);
    unawaited(reconcileActiveCalls());
  }

  static Future<void> reconcileActiveCalls() async {
    if (!isSupported) return;
    try {
      final active = await FlutterCallkitIncoming.activeCalls();
      if (active is! List || active.isEmpty) return;
      for (final raw in active) {
        if (raw is! Map) continue;
        final body = raw.map((key, value) => MapEntry(key.toString(), value));
        final extra = _extraFromEventBody(body);
        final callId = callIdFromUuid(body['id']?.toString()) ??
            int.tryParse(extra?['session_id']?.toString() ?? '');
        if (callId == null) continue;
        final accepted = body['accepted'] == true ||
            body['isAccepted'] == true ||
            body['accepted']?.toString() == '1';
        if (accepted) {
          await _openAcceptedCall(extra ?? body, callId: callId);
        }
      }
    } catch (e, st) {
      debugPrint('[CallKit] reconcileActiveCalls failed: $e\n$st');
    }
  }

  static Future<void> showIncomingCall({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
    bool isVideo = false,
    String? avatarUrl,
  }) async {
    if (!isSupported) return;
    if (_shownCallIds.contains(callId)) return;
    _shownCallIds.add(callId);

    await initialize();
    unawaited(stopServiceWorkerCallRing(callId));

    final extra = {
      'type': 'familychat_call',
      'session_id': '$callId',
      'thread_id': '$threadId',
      'caller_user_id': '$callerUserId',
      'caller_name': callerName,
      'is_video': isVideo ? '1' : '0',
    };

    final params = CallKitParams(
      id: callUuid(callId),
      nameCaller: callerName,
      appName: 'Family Space',
      avatar: avatarUrl,
      handle: callerName,
      type: isVideo ? 1 : 0,
      textAccept: 'Принять',
      textDecline: 'Отклонить',
      duration: 45000,
      extra: extra,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Пропущенный звонок',
        callbackText: 'Перезвонить',
      ),
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0F1419',
        actionColor: '#4CAF50',
        textColor: '#FFFFFF',
        incomingCallNotificationChannelName: 'Звонки',
        missedCallNotificationChannelName: 'Пропущенные звонки',
        isShowCallID: false,
      ),
      ios: IOSParams(
        handleType: 'generic',
        supportsVideo: isVideo,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  static Future<void> showIncomingFromPushData(Map<String, dynamic> data) async {
    if (data['type']?.toString() != 'familychat_call') return;
    final callId = int.tryParse(data['session_id']?.toString() ?? '');
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    if (callId == null || threadId == null) return;
    final callerUserId =
        int.tryParse(data['caller_user_id']?.toString() ?? '') ?? 0;
    final callerName = data['caller_name']?.toString().trim();
    final isVideo = data['is_video']?.toString() == '1' ||
        data['is_video'] == true ||
        data['is_video'] == 1;
    await showIncomingCall(
      callId: callId,
      threadId: threadId,
      callerUserId: callerUserId,
      callerName: callerName != null && callerName.isNotEmpty
          ? callerName
          : 'Family Space',
      isVideo: isVideo,
    );
  }

  static Future<void> endCall(int callId) async {
    if (!isSupported) return;
    _shownCallIds.remove(callId);
    try {
      await FlutterCallkitIncoming.endCall(callUuid(callId));
    } catch (e) {
      debugPrint('[CallKit] endCall failed: $e');
    }
  }

  static Future<void> endAllCalls() async {
    if (!isSupported) return;
    _shownCallIds.clear();
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (e) {
      debugPrint('[CallKit] endAllCalls failed: $e');
    }
  }

  static void _onCallEvent(CallEvent? event) {
    if (event == null) return;
    final body = event.body;
    if (body is! Map) return;
    final map = body.map((key, value) => MapEntry(key.toString(), value));
    final extra = _extraFromEventBody(map) ?? map;
    final callId = callIdFromUuid(map['id']?.toString()) ??
        int.tryParse(extra['session_id']?.toString() ?? '');

    switch (event.event) {
      case Event.actionCallAccept:
        if (callId != null) {
          unawaited(_onAccepted(extra, callId: callId));
        }
        break;
      case Event.actionCallDecline:
        if (callId != null) {
          unawaited(_onDeclined(extra, callId: callId));
        }
        break;
      case Event.actionCallEnded:
      case Event.actionCallTimeout:
        if (callId != null) {
          unawaited(_onEnded(callId));
        }
        break;
      default:
        break;
    }
  }

  static Future<void> _onAccepted(
    Map<String, dynamic> extra, {
    required int callId,
  }) async {
    _shownCallIds.remove(callId);
    unawaited(stopServiceWorkerCallRing(callId));

    if (FamilyChatForegroundBridge.isAppInBackground()) {
      await FamilyChatForegroundBridge.bringToForegroundIfNeeded(forCall: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    try {
      final repo = FamilyChatRepository(ApiClient());
      await repo.callAction(callId, 'accept');
    } catch (e, st) {
      debugPrint('[CallKit] accept API failed: $e\n$st');
      await endCall(callId);
      return;
    }

    try {
      await FlutterCallkitIncoming.setCallConnected(callUuid(callId));
    } catch (_) {}

    await _openAcceptedCall(extra, callId: callId);
  }

  static Future<void> _openAcceptedCall(
    Map<String, dynamic> extra, {
    required int callId,
  }) async {
    final handler = onAccepted;
    if (handler != null) {
      await handler(extra, callId);
      return;
    }
  }

  static Future<void> _onDeclined(
    Map<String, dynamic> extra, {
    required int callId,
  }) async {
    await NotificationCallActions.declineFromPayload(
      data: _extraFromPushData(extra),
      source: 'callkit',
    );
    await _onEnded(callId);
  }

  static Future<void> _onEnded(int callId) async {
    _shownCallIds.remove(callId);
    final handler = onEnded;
    if (handler != null) {
      await handler(callId);
      return;
    }
    unawaited(stopServiceWorkerCallRing(callId));
    await endCall(callId);
  }
}
