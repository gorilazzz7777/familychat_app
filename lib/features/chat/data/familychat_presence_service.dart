import 'package:flutter/widgets.dart';

import '../../../core/notifications/familychat_foreground_bridge.dart';
import 'familychat_realtime.dart';

/// Pushes foreground/background state to the server over WebSocket.
abstract final class FamilyChatPresenceService {
  static bool? _lastSentForeground;

  static void syncNow() {
    _send(FamilyChatForegroundBridge.isAppInForeground());
  }

  static void onLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _send(true);
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _send(false);
    }
  }

  static void onWebVisibilityChanged({required bool visible}) {
    _send(visible);
  }

  static void _send(bool foreground) {
    if (_lastSentForeground == foreground) return;
    _lastSentForeground = foreground;
    final realtime = FamilyChatRealtime.instance;
    if (!realtime.isConnected) return;
    realtime.sendPresenceUpdate(appInForeground: foreground);
  }

  /// Call after WebSocket (re)connect — resend actual foreground state.
  static void onRealtimeConnected() {
    _lastSentForeground = null;
    syncNow();
  }
}
