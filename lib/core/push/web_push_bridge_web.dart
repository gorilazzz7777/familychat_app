import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;

import '../../features/chat/data/incoming_call_coordinator.dart';
import '../routing/app_uri_parser.dart';

bool _listening = false;

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

void listenWebPushIncomingCalls() {
  if (_listening) return;
  _listening = true;

  html.window.onMessage.listen((event) {
    if (event.origin != html.window.location.origin) return;
    final raw = event.data;
    if (raw is! Map) return;
    final source = raw['source']?.toString() ?? '';
    if (source != 'familychat-fcm' && source != 'familychat-fcm-sw') return;
    final data = Map<String, dynamic>.from(raw);
    if (data['type']?.toString() != 'familychat_call') return;
    IncomingCallCoordinator.instance.presentFromPushData(data);
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
