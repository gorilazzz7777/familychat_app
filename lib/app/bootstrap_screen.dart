import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/providers/app_providers.dart';
import '../core/routing/app_uri_parser.dart';
import '../core/push/push_navigation.dart';
import '../core/session/auth_session_bus.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/chat/data/chat_scheduled_send_service.dart';
import '../features/chat/data/familychat_realtime.dart';
import '../core/push/push_registration_service.dart';
import '../core/push/web_push_bridge.dart';
import '../core/theme/theme_seed_controller.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import 'shell_screen.dart';
import 'push_permission_prompt.dart';
import 'app_actions_scope.dart';

class BootstrapScreen extends ConsumerStatefulWidget {
  const BootstrapScreen({super.key});

  @override
  ConsumerState<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends ConsumerState<BootstrapScreen> {
  static const _pendingInviteKey = 'pending_invite_token';

  bool _checking = true;
  bool _loggedIn = false;
  bool _ready = false;
  Map<String, dynamic>? _status;
  String? _bootError;
  String? _pendingInvite;

  final _appLinks = AppLinks();
  StreamSubscription<String>? _accessSub;
  StreamSubscription<void>? _invalidSub;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      listenWebPushIncomingCalls();
      unawaited(initWebFcmForeground());
    }
    _accessSub = AuthSessionBus.instance.onAccessRefreshed.listen((access) {
      unawaited(FamilyChatRealtime.instance.connect(access));
    });
    _invalidSub = AuthSessionBus.instance.onSessionInvalidated.listen((_) {
      if (!mounted) return;
      unawaited(_logout());
    });
    unawaited(_boot());
    if (!kIsWeb) {
      _listenInvites();
    }
  }

  @override
  void dispose() {
    _accessSub?.cancel();
    _invalidSub?.cancel();
    super.dispose();
  }

  Future<void> _listenInvites() async {
    final initial = await _appLinks.getInitialLink();
    if (initial != null) await _handleInviteUri(initial);
    _appLinks.uriLinkStream.listen(_handleInviteUri);
  }

  Future<void> _handleInviteUri(Uri uri) async {
    final token = extractInviteToken(uri);
    if (token == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingInviteKey, token);
    if (mounted) setState(() => _pendingInvite = token);
  }

  Future<void> _consumePendingInvite() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_pendingInviteKey);
    if (token == null || token.isEmpty) return;
    try {
      await ref.read(familychatRepositoryProvider).fetchInviteInfo(token);
      if (mounted) setState(() => _pendingInvite = token);
    } catch (_) {
      await prefs.remove(_pendingInviteKey);
      if (mounted) setState(() => _pendingInvite = null);
    }
  }

  Future<void> _clearPendingInvite() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingInviteKey);
    if (mounted) setState(() => _pendingInvite = null);
  }

  OAuthCallbackResult? _readOAuthCallback() {
    return parseOAuthCallback(Uri.base);
  }

  Future<void> _handleWebEntry() async {
    if (!kIsWeb) return;
    final oauth = _readOAuthCallback();
    if (oauth != null && oauth.isOk && oauth.sessionCode != null) {
      try {
        await ref.read(authRepositoryProvider).consumeSession(
              provider: oauth.provider,
              sessionCode: oauth.sessionCode!,
            );
      } catch (_) {}
    }
    final inviteToken = extractInviteToken(Uri.base);
    if (inviteToken != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingInviteKey, inviteToken);
      _pendingInvite = inviteToken;
    }
    final pendingCall = readWebPendingCallLaunch();
    if (pendingCall != null) {
      pendingCallPushData = pendingCall;
    }
  }

  Future<bool> _hasSession() async {
    try {
      return await ref.read(authRepositoryProvider).hasSession();
    } catch (_) {
      return false;
    }
  }

  Future<void> _boot() async {
    setState(() {
      _checking = true;
      _bootError = null;
    });
    await _handleWebEntry();
    await _consumePendingInvite();
    if (!await _hasSession()) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _loggedIn = false;
      });
      return;
    }

    Map<String, dynamic>? st;
    Object? statusError;
    try {
      st = await ref.read(familychatRepositoryProvider).status();
      try {
        await ref.read(themeSeedProvider.notifier).syncFromStatus(st);
      } catch (_) {}
    } catch (e) {
      statusError = e;
    }

    final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
    if (token != null && token.isNotEmpty) {
      unawaited(FamilyChatRealtime.instance.connect(token));
    }
    unawaited(PushRegistrationService.registerIfPossible(
      client: ref.read(apiClientProvider),
      repository: ref.read(familychatRepositoryProvider),
    ));

    if (!mounted) return;
    if (st == null) {
      final stillLoggedIn = await _hasSession();
      if (!mounted) return;
      setState(() {
        _checking = false;
        _loggedIn = stillLoggedIn;
        _bootError = statusError is DioException
            ? 'Ошибка загрузки (${statusError.response?.statusCode ?? 'сеть'})'
            : 'Не удалось загрузить данные';
      });
      return;
    }

    final status = st;
    setState(() {
      _checking = false;
      _loggedIn = true;
      _status = status;
      _ready = status['onboarding_complete'] == true &&
          status['has_family'] == true;
      _bootError = null;
    });
    _syncAppActions();
  }

  void _syncAppActions() {
    final status = _status;
    if (!_loggedIn || !_ready || status == null) return;
    AppActions.bind(
      status: status,
      onLogout: _logout,
      onStatusChanged: _refreshStatus,
    );
  }

  Future<void> _refreshStatus() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      await ref.read(themeSeedProvider.notifier).syncFromStatus(st);
      if (!mounted) return;
      setState(() => _status = st);
      _syncAppActions();
    } catch (_) {}
  }

  Future<void> _logout() async {
    final nav = familyChatNavigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.popUntil((route) => route.isFirst);
    }
    await FamilyChatRealtime.instance.disconnect();
    ChatScheduledSendService.instance.stop();
    PushRegistrationService.resetSession();
    await ref.read(themeSeedProvider.notifier).resetToDefault();
    await ref.read(authRepositoryProvider).logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('familychat_push_prompt_dismissed');
    await prefs.remove('familychat_web_push_registered');
    await prefs.remove(_pendingInviteKey);
    if (!mounted) return;
    setState(() {
      _loggedIn = false;
      _ready = false;
      _status = null;
      _checking = false;
      _pendingInvite = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_bootError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_bootError!),
              const SizedBox(height: 16),
              FilledButton(onPressed: _boot, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    if (!_loggedIn) {
      return LoginScreen(onLoggedIn: _boot);
    }
    return PushPermissionPrompt(
      child: !_ready
          ? OnboardingScreen(
              onComplete: _boot,
              onLogout: _logout,
              pendingInviteToken: _pendingInvite,
              onPendingInviteCleared: _clearPendingInvite,
            )
          : ShellScreen(
              status: _status!,
              onLogout: _logout,
              onStatusChanged: _refreshStatus,
            ),
    );
  }
}
