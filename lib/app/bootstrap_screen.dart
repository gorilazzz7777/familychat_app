import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/cache/familychat_local_cache.dart';
import '../core/providers/app_providers.dart';
import '../core/routing/app_uri_parser.dart';
import '../core/push/push_navigation.dart';
import '../core/session/auth_session_bus.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/chat/data/chat_offline_sync.dart';
import '../features/chat/data/chat_scheduled_send_service.dart';
import '../features/chat/data/familychat_realtime.dart';
import '../features/chat/presentation/chat_conversation_screen.dart';
import '../features/chat/presentation/friend_invite_flow.dart';
import '../core/push/push_registration_service.dart';
import '../core/push/web_push_bridge.dart';
import '../core/theme/theme_seed_controller.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/onboarding/presentation/family_transfer_flow.dart';
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
  static const _pendingFriendInviteKey = 'pending_friend_invite_token';

  bool _checking = true;
  bool _loggedIn = false;
  bool _ready = false;
  Map<String, dynamic>? _status;
  String? _bootError;
  String? _pendingInvite;
  String? _pendingFriendInvite;
  bool _friendInviteHandling = false;
  bool _familyTransferHandling = false;
  Map<String, dynamic>? _transferOnboardingSession;

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
    final friendToken = extractFriendInviteToken(uri);
    if (friendToken != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingFriendInviteKey, friendToken);
      if (mounted) setState(() => _pendingFriendInvite = friendToken);
      return;
    }
    final token = extractInviteToken(uri);
    if (token == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingInviteKey, token);
    if (mounted) setState(() => _pendingInvite = token);
    if (_ready) {
      unawaited(_maybeHandleFamilyTransfer());
    }
  }

  /// Читает pending invite из prefs без сетевой валидации (не блокирует UI).
  Future<void> _hydratePendingInvitesFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final friendToken = prefs.getString(_pendingFriendInviteKey);
      final token = prefs.getString(_pendingInviteKey);
      if (!mounted) return;
      setState(() {
        _pendingFriendInvite =
            (friendToken != null && friendToken.isNotEmpty) ? friendToken : null;
        _pendingInvite = (token != null && token.isNotEmpty) ? token : null;
      });
    } catch (_) {}
  }

  /// Фоновая проверка invite; невалидные токены убираем.
  Future<void> _validatePendingInvitesInBackground() async {
    await _hydratePendingInvitesFromPrefs();
    final prefs = await SharedPreferences.getInstance();
    final friendToken = prefs.getString(_pendingFriendInviteKey);
    if (friendToken != null && friendToken.isNotEmpty) {
      try {
        await ref
            .read(familychatRepositoryProvider)
            .fetchFriendInviteInfo(friendToken);
        if (mounted) setState(() => _pendingFriendInvite = friendToken);
      } catch (_) {
        await prefs.remove(_pendingFriendInviteKey);
        if (mounted) setState(() => _pendingFriendInvite = null);
      }
    }
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

  Future<void> _clearPendingFriendInvite() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingFriendInviteKey);
    if (mounted) setState(() => _pendingFriendInvite = null);
  }

  OAuthCallbackResult? _readOAuthCallback() {
    return parseOAuthCallback(Uri.base);
  }

  /// Локальная часть web-entry: invite из URL, pending call. Без сети.
  Future<void> _persistWebEntryLocal() async {
    if (!kIsWeb) return;
    final inviteToken = extractInviteToken(Uri.base);
    if (inviteToken != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingInviteKey, inviteToken);
      _pendingInvite = inviteToken;
    }
    final friendToken = extractFriendInviteToken(Uri.base);
    if (friendToken != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingFriendInviteKey, friendToken);
      _pendingFriendInvite = friendToken;
    }
    final pendingCall = readWebPendingCallLaunch();
    if (pendingCall != null) {
      pendingCallPushData = pendingCall;
    }
  }

  /// OAuth return: consume session (нужен спиннер).
  Future<void> _consumeOAuthIfNeeded() async {
    if (!kIsWeb) return;
    final oauth = _readOAuthCallback();
    if (oauth == null || !oauth.isOk || oauth.sessionCode == null) return;
    try {
      await ref.read(authRepositoryProvider).consumeSession(
            provider: oauth.provider,
            sessionCode: oauth.sessionCode!,
          );
    } catch (_) {}
  }

  Future<bool> _hasSession() async {
    try {
      return await ref.read(authRepositoryProvider).hasSession();
    } catch (_) {
      return false;
    }
  }

  bool _isAuthFailure(Object? error) {
    if (error is! DioException) return false;
    final code = error.response?.statusCode;
    return code == 401 || code == 403;
  }

  void _enterWithStatus(Map<String, dynamic> status, {required bool fromCache}) {
    setState(() {
      _checking = false;
      _loggedIn = true;
      _status = status;
      _ready = status['onboarding_complete'] == true &&
          status['has_family'] == true;
      _bootError = null;
    });
    if (fromCache) {
      ChatOfflineSync.instance.setOnline(false);
    } else {
      ChatOfflineSync.instance.setOnline(true);
      unawaited(FamilyChatLocalCache.saveStatus(status));
    }
    _syncAppActions();
    if (_ready) {
      unawaited(_maybeHandleFriendInvite());
      unawaited(_maybeHandleFamilyTransfer());
    }
  }

  Future<void> _showLogin() async {
    if (!mounted) return;
    setState(() {
      _checking = false;
      _loggedIn = false;
      _ready = false;
      _status = null;
      _bootError = null;
      _transferOnboardingSession = null;
    });
    unawaited(_validatePendingInvitesInBackground());
  }

  Future<void> _boot() async {
    setState(() {
      _checking = true;
      _bootError = null;
    });

    await _persistWebEntryLocal();
    // OAuth callback — единственный случай, где сеть до login допустима.
    await _consumeOAuthIfNeeded();

    if (!await _hasSession()) {
      await _showLogin();
      return;
    }

    // Токен есть — спиннер, пока проверяем status.
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

    if (!mounted) return;

    // Сессию могли сбросить interceptor'ом во время status/refresh.
    if (!await _hasSession()) {
      await _showLogin();
      return;
    }

    final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
    if (token != null && token.isNotEmpty) {
      unawaited(FamilyChatRealtime.instance.connect(token));
    }
    unawaited(PushRegistrationService.registerIfPossible(
      client: ref.read(apiClientProvider),
      repository: ref.read(familychatRepositoryProvider),
    ));
    unawaited(_validatePendingInvitesInBackground());

    if (!mounted) return;

    if (st != null) {
      _enterWithStatus(st, fromCache: false);
      return;
    }

    // Auth fail → сразу login (без экрана ошибки и без сетевого logout).
    if (_isAuthFailure(statusError)) {
      await ref.read(apiClientProvider).tokenStorage.clear();
      await FamilyChatLocalCache.clearStatus();
      await _showLogin();
      return;
    }

    // Сеть/прочее → пробуем кэш status (офлайн-старт как в shell).
    final cached = await FamilyChatLocalCache.readStatus();
    if (cached != null && cached.isNotEmpty) {
      try {
        await ref.read(themeSeedProvider.notifier).syncFromStatus(cached);
      } catch (_) {}
      if (!mounted) return;
      _enterWithStatus(cached, fromCache: true);
      return;
    }

    // Нет кэша — оставляем retry.
    setState(() {
      _checking = false;
      _loggedIn = true;
      _bootError = statusError is DioException
          ? 'Ошибка загрузки (${statusError.response?.statusCode ?? 'сеть'})'
          : 'Не удалось загрузить данные';
    });
  }

  Future<void> _maybeHandleFamilyTransfer() async {
    final token = _pendingInvite;
    if (token == null ||
        token.isEmpty ||
        _familyTransferHandling ||
        !_ready) {
      return;
    }
    _familyTransferHandling = true;
    try {
      final result = await confirmAndTransferFamilyInvite(
        context,
        ref.read(familychatRepositoryProvider),
        token,
      );
      await _clearPendingInvite();
      if (!mounted || result == null) return;
      if (result['needs_profile'] == true) {
        // Профиль отсутствует — обычный онбординг по invite.
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pendingInviteKey, token);
        setState(() {
          _ready = false;
          _transferOnboardingSession = null;
          _pendingInvite = token;
        });
        return;
      }
      final questions =
          (result['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final sessionId = result['onboarding_session_id'] as int?;
      if (sessionId == null) {
        await _boot();
        return;
      }
      setState(() {
        _ready = false;
        _transferOnboardingSession = {
          'onboarding_session_id': sessionId,
          'questions': questions,
        };
      });
    } finally {
      _familyTransferHandling = false;
    }
  }

  Future<void> _maybeHandleFriendInvite() async {
    final token = _pendingFriendInvite;
    if (token == null || token.isEmpty || _friendInviteHandling) return;
    _friendInviteHandling = true;
    try {
      final result = await confirmAndAcceptFriendInvite(
        context,
        ref.read(familychatRepositoryProvider),
        token,
      );
      await _clearPendingFriendInvite();
      if (!mounted || result == null) return;
      final thread = result['thread'] as Map<String, dynamic>?;
      if (thread == null) return;
      final threadId = thread['id'] is int
          ? thread['id'] as int
          : int.tryParse('${thread['id']}');
      if (threadId == null) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatConversationScreen(
            threadId: threadId,
            title: thread['title']?.toString() ?? 'Чат',
            defaultTitle: thread['default_title']?.toString() ??
                thread['title']?.toString() ??
                'Чат',
            customTitle: thread['custom_title']?.toString() ?? '',
            kind: thread['kind']?.toString() ?? 'friend_dm',
            peerUserId: thread['peer_user_id'] as int?,
            initialCanSend: thread['can_send'] != false,
          ),
        ),
      );
    } finally {
      _friendInviteHandling = false;
    }
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
      await FamilyChatLocalCache.saveStatus(st);
      ChatOfflineSync.instance.setOnline(true);
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
    await FamilyChatLocalCache.clearStatus();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('familychat_push_prompt_dismissed');
    await prefs.remove('familychat_web_push_registered');
    await prefs.remove(_pendingInviteKey);
    await prefs.remove(_pendingFriendInviteKey);
    if (!mounted) return;
    setState(() {
      _loggedIn = false;
      _ready = false;
      _status = null;
      _checking = false;
      _bootError = null;
      _pendingInvite = null;
      _pendingFriendInvite = null;
      _transferOnboardingSession = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: scheme.surface,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/logo/logo.png',
                width: 88,
                height: 88,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.favorite_rounded,
                  size: 64,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Загрузка…',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      );
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
              onComplete: () {
                setState(() => _transferOnboardingSession = null);
                _boot();
              },
              onLogout: _logout,
              pendingInviteToken: _pendingInvite,
              pendingFriendInviteToken: _pendingFriendInvite,
              onPendingInviteCleared: _clearPendingInvite,
              transferSession: _transferOnboardingSession,
            )
          : ShellScreen(
              status: _status!,
              onLogout: _logout,
              onStatusChanged: _refreshStatus,
            ),
    );
  }
}
