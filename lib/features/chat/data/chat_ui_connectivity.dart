import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/notifications/familychat_foreground_bridge.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_network_status.dart';
import 'familychat_realtime.dart';

/// App-bar / UI connectivity: WebSocket-first, HTTP ping only after grace.
///
/// Separate from [ChatOfflineSync.isOnline] (outbox / API reachability).
class ChatUiConnectivity extends ChangeNotifier {
  ChatUiConnectivity._();

  static final ChatUiConnectivity instance = ChatUiConnectivity._();

  static const gracePeriod = Duration(seconds: 4);

  bool _started = false;
  bool _uiOnline = true;
  Timer? _graceTimer;
  int _pingGeneration = 0;
  FamilyChatRepository? _repo;
  void Function(bool online)? _syncApiOnline;

  bool get isOnline => _uiOnline;

  /// Bind repository and start listening (idempotent). Call from Shell.
  void start(
    FamilyChatRepository repo, {
    void Function(bool online)? syncApiOnline,
  }) {
    _repo = repo;
    _syncApiOnline = syncApiOnline;
    // WS up ⇒ outbox may deliver (HTTP often works too). Keep flags aligned
    // even on re-bind after bootstrap set ChatOfflineSync offline from cache.
    if (FamilyChatRealtime.instance.isConnected) {
      _markReachable(syncApi: true);
    }
    if (_started) return;
    _started = true;
    FamilyChatRealtime.instance.addListener(_onRealtime);
    if (!FamilyChatRealtime.instance.isConnected &&
        FamilyChatForegroundBridge.isAppInForeground()) {
      // Cold start / not yet connected — wait grace, then ping.
      _beginGrace();
    }
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _graceTimer?.cancel();
    _graceTimer = null;
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    _repo = null;
    _syncApiOnline = null;
  }

  void onAppResumed() {
    if (!_started) return;
    if (FamilyChatRealtime.instance.isConnected) {
      _markReachable(syncApi: true);
      return;
    }
    _beginGrace();
  }

  void onAppBackground() {
    if (!_started) return;
    _cancelGrace();
    // Do not flip UI offline while backgrounded.
  }

  /// HTTP became reachable (outbox ping / boot) — clear banner early.
  void onHttpReachable() {
    if (!_started) return;
    _markReachable(syncApi: false);
  }

  void _onRealtime(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev == 'ws_connected') {
      // UI was already flipping online here; also unlock outbox — otherwise
      // clock bubbles stay forever when ChatOfflineSync still thinks offline
      // (e.g. after cache-first boot) while the header shows no "waiting".
      _markReachable(syncApi: true);
      return;
    }
    if (ev == 'ws_disconnected') {
      if (!FamilyChatForegroundBridge.isAppInForeground()) return;
      _beginGrace();
    }
  }

  void _markReachable({required bool syncApi}) {
    _setOnline(true);
    _cancelGrace();
    if (syncApi) {
      _syncApiOnline?.call(true);
    }
  }

  void _beginGrace() {
    _graceTimer?.cancel();
    _graceTimer = Timer(gracePeriod, () {
      unawaited(_afterGrace());
    });
  }

  void _cancelGrace() {
    _graceTimer?.cancel();
    _graceTimer = null;
  }

  Future<void> _afterGrace() async {
    if (!_started) return;
    if (!FamilyChatForegroundBridge.isAppInForeground()) return;
    if (FamilyChatRealtime.instance.isConnected) {
      _markReachable(syncApi: true);
      return;
    }
    final repo = _repo;
    if (repo == null) {
      _setOnline(false);
      return;
    }
    final gen = ++_pingGeneration;
    final online = await ChatNetworkStatus.isOnline(() async {
      await repo.status(timeout: const Duration(seconds: 3));
    });
    if (kDebugMode) {
      debugPrint('[ChatUiConnectivity] grace ping -> $online');
    }
    if (!_started || gen != _pingGeneration) return;
    if (FamilyChatRealtime.instance.isConnected) {
      _markReachable(syncApi: true);
      return;
    }
    _syncApiOnline?.call(online);
    _setOnline(online);
  }

  void _setOnline(bool online) {
    if (_uiOnline == online) return;
    _uiOnline = online;
    notifyListeners();
  }
}
