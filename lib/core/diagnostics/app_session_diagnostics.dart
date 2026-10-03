import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../network/chat_network_link.dart';
import '../../features/chat/data/chat_ui_connectivity.dart';
import 'session_log.dart';

/// Debug-only app-wide probes that feed [SessionLog].
///
/// Covers lifecycle, network, navigation, shell tabs, bootstrap, FC chat,
/// WS, push, Flutter/platform errors — not only Telegram chat opens.
class AppSessionDiagnostics {
  AppSessionDiagnostics._();

  static final AppSessionDiagnostics instance = AppSessionDiagnostics._();

  static bool get enabled => SessionLog.enabled;

  final SessionNavObserver navigatorObserver = SessionNavObserver();

  StreamSubscription<ChatNetworkLinkKind>? _netSub;
  Timer? _heartbeat;
  bool _started = false;
  bool _listeningUi = false;

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  ChatNetworkLinkKind _netKind = ChatNetworkLinkKind.unknown;
  bool _uiOnline = true;
  String _shellTab = 'unknown';
  String? _route;
  String? _fcOpenThread;
  int? _tgOpenChatId;
  String _tgConn = '';
  String _tgPhase = '';
  bool? _tgProxy;

  FlutterExceptionHandler? _prevFlutterOnError;
  bool Function(Object, StackTrace)? _prevPlatformOnError;

  /// Compact ambient state attached to `app.*` / `diag` events.
  Map<String, Object?> get ambient => {
        'life': _lifecycle.name,
        'net': _netKind.name,
        'uiOnline': _uiOnline,
        'shell': _shellTab,
        if (_route != null) 'route': _route,
        if (_fcOpenThread != null) 'fcThread': _fcOpenThread,
        if (_tgOpenChatId != null) 'tgChat': _tgOpenChatId,
        if (_tgConn.isNotEmpty) 'tgConn': _tgConn,
        if (_tgPhase.isNotEmpty) 'tgPhase': _tgPhase,
        if (_tgProxy != null) 'tgProxy': _tgProxy,
      };

  void start() {
    if (!enabled || _started) return;
    _started = true;
    unawaited(SessionLog.instance.ensureStarted());
    _installErrorHandlers();
    _watchNetwork();
    _watchUiConnectivity();
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) {
      snapshot('heartbeat');
    });
    SessionLog.instance.event('app', 'diag_start', {
      ...ambient,
      'platform': defaultTargetPlatform.name,
    });
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    unawaited(_netSub?.cancel());
    _netSub = null;
    if (_listeningUi) {
      ChatUiConnectivity.instance.removeListener(_onUiConnectivity);
      _listeningUi = false;
    }
    _restoreErrorHandlers();
  }

  void snapshot(String why) {
    if (!enabled) return;
    SessionLog.instance.event('app', 'snapshot', {
      'why': why,
      ...ambient,
      'frames': SchedulerBinding.instance.schedulerPhase.name,
    });
  }

  void lifecycle(AppLifecycleState state) {
    if (!enabled) return;
    final prev = _lifecycle;
    _lifecycle = state;
    if (prev == state) return;
    SessionLog.instance.event('app.life', 'change', {
      'from': prev.name,
      'to': state.name,
      ...ambient,
    });
  }

  void shellTab(String tab, {String? from}) {
    if (!enabled) return;
    final prev = _shellTab;
    if (prev == tab) return;
    _shellTab = tab;
    SessionLog.instance.event('app.shell', 'tab', {
      'from': from ?? prev,
      'to': tab,
      ...ambient,
    });
  }

  void setRoute(String? route) {
    if (!enabled) return;
    if (_route == route) return;
    final prev = _route;
    _route = route;
    SessionLog.instance.event('app.nav', 'route', {
      'from': prev,
      'to': route,
      ...ambient,
    });
  }

  void bootstrap(String evt, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    SessionLog.instance.event('app.boot', evt, {...fields, ...ambient});
  }

  void fcChatOpen({
    required int threadId,
    String? title,
    String? kind,
    int? peerUserId,
  }) {
    if (!enabled) return;
    _fcOpenThread = '$threadId';
    SessionLog.instance.event('fc.chat', 'open', {
      'threadId': threadId,
      'title': SessionLog.textPreview(title, max: 80),
      'kind': kind,
      'peerUserId': peerUserId,
      ...ambient,
    });
  }

  void fcChatClose({required int threadId}) {
    if (!enabled) return;
    if (_fcOpenThread == '$threadId') _fcOpenThread = null;
    SessionLog.instance.event('fc.chat', 'close', {
      'threadId': threadId,
      ...ambient,
    });
  }

  void setTgOpenChat(int? chatId) {
    _tgOpenChatId = chatId;
  }

  /// Called from TDLib service when connection / auth / proxy changes.
  void setTgState({
    String? conn,
    String? phase,
    bool? proxy,
  }) {
    if (conn != null) _tgConn = conn;
    if (phase != null) _tgPhase = phase;
    if (proxy != null) _tgProxy = proxy;
  }

  void ws(String evt, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    SessionLog.instance.throttled(
      'fc.ws',
      evt,
      key: 'ws:$evt',
      minInterval: const Duration(seconds: 2),
      fields: {...fields, ...ambient},
    );
  }

  void push(String evt, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    SessionLog.instance.event('app.push', evt, {...fields, ...ambient});
  }

  void auth(String system, String phase, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    SessionLog.instance.event('app.auth', 'phase', {
      'system': system,
      'phase': phase,
      ...fields,
      ...ambient,
    });
  }

  void offlineSync(bool online) {
    if (!enabled) return;
    SessionLog.instance.event('fc.sync', online ? 'online' : 'offline', ambient);
  }

  void uiOnline(bool online) {
    if (!enabled) return;
    if (_uiOnline == online) return;
    _uiOnline = online;
    SessionLog.instance.event('app.net', 'ui_online', {
      'online': online,
      ...ambient,
    });
  }

  void networkKind(ChatNetworkLinkKind kind) {
    if (!enabled) return;
    final prev = _netKind;
    if (prev == kind) return;
    _netKind = kind;
    SessionLog.instance.event('app.net', 'link', {
      'from': prev.name,
      'to': kind.name,
      ...ambient,
    });
  }

  void error(
    String source,
    Object error, {
    StackTrace? stack,
  }) {
    if (!enabled) return;
    SessionLog.instance.event('app.error', source, {
      'err': error.toString(),
      'stack': stack == null
          ? null
          : SessionLog.textPreview(stack.toString(), max: 800),
      ...ambient,
    });
  }

  void _watchNetwork() {
    if (kIsWeb) return;
    unawaited(_netSub?.cancel());
    _netSub = ChatNetworkLink.watch().listen(networkKind);
  }

  void _watchUiConnectivity() {
    if (_listeningUi) return;
    _uiOnline = ChatUiConnectivity.instance.isOnline;
    ChatUiConnectivity.instance.addListener(_onUiConnectivity);
    _listeningUi = true;
  }

  void _onUiConnectivity() {
    uiOnline(ChatUiConnectivity.instance.isOnline);
  }

  void _installErrorHandlers() {
    _prevFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      error(
        'flutter',
        details.exceptionAsString(),
        stack: details.stack,
      );
      _prevFlutterOnError?.call(details);
    };

    _prevPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (err, stack) {
      error('platform', err, stack: stack);
      return _prevPlatformOnError?.call(err, stack) ?? false;
    };
  }

  void _restoreErrorHandlers() {
    if (_prevFlutterOnError != null) {
      FlutterError.onError = _prevFlutterOnError;
      _prevFlutterOnError = null;
    }
    if (_prevPlatformOnError != null) {
      PlatformDispatcher.instance.onError = _prevPlatformOnError;
      _prevPlatformOnError = null;
    }
  }
}

/// Logs top-level route push/pop/replace (debug only).
class SessionNavObserver extends NavigatorObserver {
  String? _nameOf(Route<dynamic>? route) {
    if (route == null) return null;
    final settings = route.settings;
    final name = settings.name;
    if (name != null && name.isNotEmpty) return name;
    final args = settings.arguments;
    if (args != null) return args.runtimeType.toString();
    return route.runtimeType.toString();
  }

  void _emit(String evt, Route<dynamic>? route, Route<dynamic>? previous) {
    if (!AppSessionDiagnostics.enabled) return;
    AppSessionDiagnostics.instance.setRoute(_nameOf(route));
    SessionLog.instance.event('app.nav', evt, {
      'route': _nameOf(route),
      'prev': _nameOf(previous),
      ...AppSessionDiagnostics.instance.ambient,
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit('push', route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit('pop', previousRoute, route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _emit('replace', newRoute, oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emit('remove', previousRoute, route);
  }
}
