import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;

import '../../features/chat/data/familychat_realtime.dart';
import '../../features/chat/data/incoming_call_coordinator.dart';
import '../routing/app_uri_parser.dart';
import 'push_navigation.dart';

bool _listening = false;
StreamSubscription<html.Event>? _visibilitySub;

bool _openedFromTap(Map<String, dynamic> data) {
  final raw = data['opened_from_tap'];
  return raw == true || raw == 1 || raw?.toString() == 'true';
}

void _applyIncomingWebPush(Map<String, dynamic> data) {
  final type = data['type']?.toString() ?? '';
  if (type == 'familychat_call') {
    IncomingCallCoordinator.instance.presentFromPushData(data);
    return;
  }
  final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
  final messageId = int.tryParse(data['message_id']?.toString() ?? '');
  final isChat = type == 'familychat_chat' ||
      (data['deeplink']?.toString() == 'chat' && threadId != null);
  if (!isChat) return;

  FamilyChatRealtime.instance.emitSyntheticEvent({
    'event': 'chat_refresh',
    if (threadId != null) 'thread_id': threadId,
    if (messageId != null) 'message_id': messageId,
  });
  if (_openedFromTap(data)) {
    try {
      html.window.sessionStorage.remove('familychat_pending_chat');
    } catch (_) {}
    openChatFromPushData({
      ...data,
      'type': 'familychat_chat',
    });
  }
}

Map<String, dynamic>? readWebPendingCallLaunch() {
  try {
    final fromUri = parseIncomingCallPushFromUri(Uri.base);
    if (fromUri != null) return fromUri;
    final raw = html.window.sessionStorage['familychat_pending_call'];
    if (raw == null || raw.isEmpty) return null;
    html.window.sessionStorage.remove('familychat_pending_call');
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}
  return null;
}

Map<String, dynamic>? readWebPendingChatLaunch() {
  try {
    final fromUri = parseIncomingChatPushFromUri(Uri.base);
    if (fromUri != null) return fromUri;
    final raw = html.window.sessionStorage['familychat_pending_chat'];
    if (raw == null || raw.isEmpty) return null;
    html.window.sessionStorage.remove('familychat_pending_chat');
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}
  return null;
}

void listenWebPushIncomingCalls() {
  if (_listening) return;
  _listening = true;

  html.window.onMessage.listen((event) {
    if (event.origin != html.window.location.origin) return;
    final raw = event.data;
    if (raw is! Map) return;
    final source = raw['source']?.toString() ?? '';
    if (source != 'familychat-fcm' && source != 'familychat-fcm-sw') return;
    _applyIncomingWebPush(Map<String, dynamic>.from(raw));
  });

  _visibilitySub?.cancel();
  _visibilitySub = html.document.onVisibilityChange.listen((_) {
    if (html.document.hidden == true) return;
    unawaited(FamilyChatRealtime.instance.reconnectAndRefresh());
  });
}

Future<void> initWebFcmForeground() async {
  try {
    final fn = js.context['familyChatInitFcmForeground'];
    if (fn != null) {
      fn.callMethod('call', [js.context]);
    }
  } catch (_) {}
}

Future<void> stopServiceWorkerCallRing(int sessionId) async {
  try {
    final registration = await html.window.navigator.serviceWorker?.ready;
    registration?.active?.postMessage({
      'type': 'familychat_call_stop',
      'session_id': '$sessionId',
    });
  } catch (_) {}
}
