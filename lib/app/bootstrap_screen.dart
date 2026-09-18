import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/cache/familychat_local_cache.dart';
import '../core/feed/feed_post_outbox.dart';
import '../core/network/native_http_adapter.dart';
import '../core/platform/app_foreground.dart';
import '../core/providers/app_providers.dart';
import '../core/impersonation/admin_enter.dart';
import '../core/impersonation/impersonation_storage.dart';
import '../core/routing/app_uri_parser.dart';
import '../core/push/push_navigation.dart';
import '../core/session/auth_session_bus.dart';
import '../features/auth/data/oauth_login_service.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/utils/guest_status.dart';
import '../features/chat/data/chat_offline_sync.dart';
import '../features/chat/data/chat_realtime_utils.dart';
import '../features/chat/data/chat_send_trace.dart';
import '../features/chat/data/chat_sync_service.dart';
import '../features/chat/data/chat_scheduled_send_service.dart';
import '../features/chat/data/familychat_realtime.dart';
import '../features/chat/data/link_preview_service.dart';
import '../features/chat/presentation/chat_conversation_screen.dart';
import '../features/chat/presentation/friend_invite_flow.dart';
import '../core/push/push_registration_service.dart';
import '../core/push/web_push_bridge.dart';
import '../core/theme/theme_seed_controller.dart';
import '../core/settings/app_settings_controller.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/onboarding/presentation/family_transfer_flow.dart';
import 'app_actions_scope.dart';
import 'chat_boot_trace.dart';
import 'push_permission_prompt.dart';
import 'shell_screen.dart';

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
      ChatSendTrace.log(
        'ws_connect_token_refresh',
        source: 'auth_bus',
        extra: {
          'tokenLen': access.length,
          'connectedBefore': FamilyChatRealtime.instance.isConnected,
        },
      );
      unawaited(FamilyChatRealtime.instance.connect(access));
    });
    _invalidSub = AuthSessionBus.instance.onSessionInvalidated.listen((_) {
      if (!mounted) return;
      unawaited(_logout(explicit: false));
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
    try {
      final initial = await _appLinks.getInitialLink().timeout(
        const Duration(seconds: 3),
      );
      if (initial != null) await _handleInviteUri(initial);
    } on TimeoutException {
      ChatBootTrace.log('invite_initial_link_timeout');
    } catch (e) {
      ChatBootTrace.log('invite_initial_link_error', detail: '$e');
    }
    _appLinks.uriLinkStream.listen(_handleInviteUri);
  }

  Future<void> _handleInviteUri(Uri uri) async {
    if (isAdminEnterUri(uri)) {
      try {
        final ok = await handleAdminEnterUri(ref, uri);
        if (ok && mounted) {
          await FamilyChatLocalCache.clearStatus();
          setState(() {
            _status = null;
            _ready = false;
          });
          unawaited(_boot());
        }
      } catch (_) {}
      return;
    }

    final oauth = parseOAuthCallback(uri);
    if (oauth != null) {
      // LoginScreen / OAuthLoginService сами consume-ят session_code.
      if (OAuthLoginService.isFlowActive) {
        await bringAppToForeground();
        return;
      }
      if (oauth.isOk && oauth.sessionCode != null) {
        final auth = ref.read(authRepositoryProvider);
        if (!await auth.hasSession()) {
          try {
            await auth.consumeSession(
              provider: oauth.provider,
              sessionCode: oauth.sessionCode!,
            );
          } catch (_) {}
        }
        await bringAppToForeground();
        if (mounted && !_loggedIn) {
          unawaited(_boot());
        }
      }
      return;
    }

    final incomingCall = parseIncomingCallPushFromUri(uri);
    if (incomingCall != null) {
      pendingCallPushData = incomingCall;
      await bringAppToForeground();
      if (_ready) flushPendingChatPush();
      return;
    }
    final incomingChat = parseIncomingChatPushFromUri(uri);
    if (incomingChat != null) {
      pendingChatPushData = incomingChat;
      await bringAppToForeground();
      if (_ready) flushPendingChatPush();
      return;
    }

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
        _pendingFriendInvite = (friendToken != null && friendToken.isNotEmpty)
            ? friendToken
            : null;
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
    final pendingChat = readWebPendingChatLaunch();
    if (pendingChat != null) {
      pendingChatPushData = pendingChat;
    }
  }

  /// OAuth return: consume session (нужен спиннер).
  Future<void> _consumeOAuthIfNeeded() async {
    Uri? uri;
    if (kIsWeb) {
      uri = Uri.base;
    } else {
      try {
        // app_links getInitialLink can hang on some iOS cold starts.
        uri = await _appLinks.getInitialLink().timeout(
          const Duration(seconds: 3),
        );
      } on TimeoutException {
        ChatBootTrace.log('oauth_initial_link_timeout');
        return;
      } catch (e) {
        ChatBootTrace.log('oauth_initial_link_error', detail: '$e');
        return;
      }
    }
    if (uri == null) return;
    final oauth = parseOAuthCallback(uri);
    if (oauth == null || !oauth.isOk || oauth.sessionCode == null) return;
    if (await ref.read(authRepositoryProvider).hasSession()) return;
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

  void _enterWithStatus(Map<String, dynamic> status,
      {required bool fromCache}) {
    setState(() {
      _checking = false;
      _loggedIn = true;
      _status = status;
      _ready =
          status['onboarding_complete'] == true && status['has_family'] == true;
      _bootError = null;
    });
    if (fromCache) {
      ChatOfflineSync.instance.setOnline(false);
    } else {
      ChatOfflineSync.instance.setOnline(true);
      unawaited(FamilyChatLocalCache.saveStatus(status));
    }
    _maybeStartChatSync(status);
    LinkPreviewService.instance.bindBackend(
      ref.read(familychatRepositoryProvider).fetchLinkPreview,
    );
    _syncAppActions();
    if (_ready) {
      unawaited(ref.read(appSettingsProvider.notifier).syncFromServer());
      unawaited(_maybeHandleFriendInvite());
      unawaited(_maybeHandleFamilyTransfer());
    }
  }

  void _maybeStartChatSync(Map<String, dynamic> status) {
    final ready =
        status['onboarding_complete'] == true && status['has_family'] == true;
    if (!ready) return;
    unawaited(
      ChatSyncService.instance.start(
        ref.read(familychatRepositoryProvider),
        currentUserId: chatAsInt(status['user_id']),
      ),
    );
  }

  /// Background status refresh after cache-first entry (no spinner).
  void _applyFreshStatus(Map<String, dynamic> status) {
    if (!mounted) return;
    final wasReady = _ready;
    final ready =
        status['onboarding_complete'] == true && status['has_family'] == true;
    setState(() {
      _status = status;
      _ready = ready;
      _bootError = null;
    });
    ChatOfflineSync.instance.setOnline(true);
    unawaited(FamilyChatLocalCache.saveStatus(status));
    ChatSyncService.instance.setCurrentUserId(
      chatAsInt(status['user_id']),
    );
    unawaited(ref.read(themeSeedProvider.notifier).syncFromStatus(status));
    _syncAppActions();
    if (ready && !wasReady) {
      _maybeStartChatSync(status);
      unawaited(ref.read(appSettingsProvider.notifier).syncFromServer());
      unawaited(_maybeHandleFriendInvite());
      unawaited(_maybeHandleFamilyTransfer());
    }
  }

  Future<void> _startSessionServices() async {
    final client = ref.read(apiClientProvider);
    FamilyChatRealtime.bindAuthRefresher(client.authRefresher);
    final token = await client.authRefresher.startWatching();
    if (token != null && token.isNotEmpty) {
      try {
        final info = await PackageInfo.fromPlatform();
        ChatSendTrace.log(
          'ws_connect_boot',
          source: 'bootstrap',
          extra: {
            'app': '${info.version}+${info.buildNumber}',
            'pkg': info.packageName,
            'platform': defaultTargetPlatform.name,
            'connectedBefore': FamilyChatRealtime.instance.isConnected,
            'tokenLen': token.length,
          },
        );
      } catch (e) {
        ChatSendTrace.log(
          'ws_connect_boot',
          source: 'bootstrap',
          detail: 'package_info_failed:$e',
          extra: {'tokenLen': token.length},
        );
      }
      unawaited(FamilyChatRealtime.instance.connect(token));
    } else {
      ChatSendTrace.log(
        'ws_connect_boot_skipped',
        source: 'bootstrap',
        detail: 'no_access_token',
      );
    }
    unawaited(PushRegistrationService.registerIfPossible(
      client: ref.read(apiClientProvider),
      repository: ref.read(familychatRepositoryProvider),
    ));
    unawaited(
      FeedPostOutbox.instance.flush(ref.read(familychatRepositoryProvider)),
    );
    unawaited(_validatePendingInvitesInBackground());
  }

  /// Network status check. [background]: UI already shown from cached status.
  Future<void> _finishBootFromNetwork({required bool background}) async {
    Map<String, dynamic>? st;
    Object? statusError;
    try {
      st = await _loadStatusOnce();
    } catch (e) {
      statusError = e;
      ChatBootTrace.log(
        'status_error',
        detail: '$e',
        extra: {'bg': background},
      );
      if (isLikelyCronetTransportFailure(e)) {
        _forceIoHttpTransport();
        try {
          ChatBootTrace.log('status_retry_dart_io');
          st = await _loadStatusOnce();
          statusError = null;
        } catch (e2) {
          statusError = e2;
          ChatBootTrace.log(
            'status_retry_failed',
            detail: '$e2',
            extra: {'bg': background},
          );
        }
      }
    }

    if (!mounted) return;

    if (!await _hasSession()) {
      await _showLogin();
      return;
    }

    try {
      await _startSessionServices().timeout(const Duration(seconds: 30));
    } catch (e) {
      ChatBootTrace.log('session_services_error', detail: '$e');
    }

    if (!mounted) return;

    if (st != null) {
      if (background) {
        _applyFreshStatus(st);
      } else {
        _enterWithStatus(st, fromCache: false);
      }
      return;
    }

    if (_isAuthFailure(statusError)) {
      final auth = ref.read(authRepositoryProvider);
      if (await auth.tryDeviceAuth()) {
        try {
          st = await _loadStatusOnce();
        } catch (_) {
          st = null;
        }
        if (st != null && mounted) {
          try {
            await _startSessionServices().timeout(const Duration(seconds: 30));
          } catch (_) {}
          if (!mounted) return;
          if (background) {
            _applyFreshStatus(st);
          } else {
            _enterWithStatus(st, fromCache: false);
          }
          return;
        }
      }
      await ref.read(apiClientProvider).tokenStorage.clear();
      await FamilyChatLocalCache.clearStatus();
      await _showLogin();
      return;
    }

    if (background) {
      // Cached UI stays; offline until next successful refresh.
      return;
    }

    // Soft fail: keep last good status instead of a hard splash error.
    final cached = await FamilyChatLocalCache.readStatus();
    if (cached != null && cached.isNotEmpty) {
      ChatBootTrace.log(
        'status_fail_use_cache',
        detail: '$statusError',
      );
      try {
        await ref.read(themeSeedProvider.notifier).syncFromStatus(cached);
      } catch (_) {}
      if (!mounted) return;
      _enterWithStatus(cached, fromCache: true);
      return;
    }

    final dioDetail = statusError is DioException
        ? '${statusError.type.name}'
            '${statusError.message != null && statusError.message!.isNotEmpty ? ':${statusError.message}' : ''}'
        : '$statusError';
    ChatBootTrace.log('status_fail_hard', detail: dioDetail);
    setState(() {
      _checking = false;
      _loggedIn = true;
      _bootError = statusError is TimeoutException
          ? 'Таймаут загрузки. Проверьте интернет.'
          : statusError is DioException
              ? 'Ошибка загрузки (${statusError.response?.statusCode ?? statusError.type.name})'
              : 'Не удалось загрузить данные';
    });
  }

  Future<Map<String, dynamic>> _loadStatusOnce() async {
    final loaded = await ref
        .read(familychatRepositoryProvider)
        .status()
        .timeout(const Duration(seconds: 20));
    try {
      await ref.read(themeSeedProvider.notifier).syncFromStatus(loaded);
    } catch (_) {}
    return loaded;
  }

  void _forceIoHttpTransport() {
    ref.read(apiClientProvider).forceDartIoTransport();
    ChatBootTrace.log('http_adapter_dart_io');
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
    LinkPreviewService.instance.bindBackend(null);
    unawaited(_validatePendingInvitesInBackground());
  }

  Future<void> _boot() async {
    ChatBootTrace.log('boot_start');
    setState(() {
      _checking = true;
      _bootError = null;
    });

    try {
      await _persistWebEntryLocal();
      ChatBootTrace.log('boot_after_web_entry');
      await _consumeOAuthIfNeeded();
      ChatBootTrace.log('boot_after_oauth');

      final auth = ref.read(authRepositoryProvider);
      if (!await _hasSession()) {
        ChatBootTrace.log('boot_ensure_session');
        try {
          await auth.ensureSession().timeout(const Duration(seconds: 45));
        } on TimeoutException {
          if (!mounted) return;
          setState(() {
            _checking = false;
            _loggedIn = false;
            _bootError = 'Таймаут входа. Проверьте интернет.';
          });
          ChatBootTrace.log('boot_ensure_session_timeout');
          return;
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _checking = false;
            _loggedIn = false;
            _bootError = e is DioException
                ? 'Не удалось войти (${e.response?.statusCode ?? 'сеть'})'
                : 'Не удалось войти. Проверьте интернет.';
          });
          ChatBootTrace.log('boot_ensure_session_error', detail: '$e');
          return;
        }
      }

      if (!await _hasSession()) {
        ChatBootTrace.log('boot_no_session_login');
        await _showLogin();
        return;
      }

      if (!await ImpersonationStorage().isActive()) {
        unawaited(auth.ensureDeviceBound());
      }
      unawaited(auth.syncGuestSessionFlag());

      // Cache-first: повторный запуск — Shell сразу, status в фоне.
      final cached = await FamilyChatLocalCache.readStatus();
      if (cached != null && cached.isNotEmpty) {
        ChatBootTrace.log('boot_cache_hit');
        Map<String, dynamic>? me;
        Object? meError;
        try {
          me = await auth.fetchMe().timeout(const Duration(seconds: 12));
        } on TimeoutException catch (e) {
          meError = e;
        } catch (e) {
          meError = e;
        }
        final meId = _userIdFromMe(me);
        final cachedId = cached['user_id'] is int
            ? cached['user_id'] as int
            : int.tryParse('${cached['user_id']}');
        if (meId != null && cachedId != null && meId != cachedId) {
          await FamilyChatLocalCache.clearStatus();
          ChatBootTrace.log(
            'boot_cache_stale',
            detail: 'me=$meId cached=$cachedId',
          );
        } else {
          // Network blip / Cronet timeout: keep cached shell instead of wipe.
          if (meError != null) {
            ChatBootTrace.log(
              'boot_cache_offline',
              detail: '$meError',
            );
            if (isLikelyCronetTransportFailure(meError)) {
              _forceIoHttpTransport();
            }
          } else {
            ChatBootTrace.log('boot_enter_cache');
          }
          try {
            await ref.read(themeSeedProvider.notifier).syncFromStatus(cached);
          } catch (_) {}
          if (!mounted) return;
          _enterWithStatus(cached, fromCache: true);
          unawaited(_finishBootFromNetwork(background: true));
          return;
        }
      }

      // Первый вход / нет кэша — ждём status (спиннер).
      ChatBootTrace.log('boot_network_status');
      await _finishBootFromNetwork(background: false);
      ChatBootTrace.log('boot_done');
    } catch (e, st) {
      ChatBootTrace.log('boot_fatal', detail: '$e');
      debugPrint('[ChatBoot] fatal: $e\n$st');
      if (!mounted) return;
      setState(() {
        _checking = false;
        _bootError = 'Ошибка запуска. Попробуйте ещё раз.';
      });
    }
  }

  int? _userIdFromMe(Map<String, dynamic>? me) {
    final user = me?['user'];
    if (user is Map) {
      final id = user['id'];
      if (id is int) return id;
      return int.tryParse('$id');
    }
    return null;
  }

  Future<void> _maybeHandleFamilyTransfer() async {
    final token = _pendingInvite;
    if (token == null || token.isEmpty || _familyTransferHandling || !_ready) {
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
      final wasReady = _ready;
      final ready =
          st['onboarding_complete'] == true && st['has_family'] == true;
      setState(() {
        _status = st;
        _ready = ready;
      });
      _syncAppActions();
      if (ready && !wasReady) {
        unawaited(ref.read(appSettingsProvider.notifier).syncFromServer());
        unawaited(_maybeHandleFriendInvite());
        unawaited(_maybeHandleFamilyTransfer());
      }
    } catch (_) {}
  }

  Future<void> _logout({bool explicit = true}) async {
    final nav = familyChatNavigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.popUntil((route) => route.isFirst);
    }
    await FamilyChatRealtime.instance.disconnect();
    await ChatSyncService.instance.stop();
    ChatScheduledSendService.instance.stop();
    PushRegistrationService.resetSession();
    await ref.read(themeSeedProvider.notifier).resetToDefault();
    await ref.read(appSettingsProvider.notifier).resetToDefaults();
    final isGuest = GuestStatus.fromStatusMap(_status);
    await ref
        .read(authRepositoryProvider)
        .logout(isGuest: isGuest, explicit: explicit);
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
      _checking = true;
      _bootError = null;
      _pendingInvite = null;
      _pendingFriendInvite = null;
      _transferOnboardingSession = null;
    });
    await _boot();
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
                  LucideIcons.heart,
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
              onImpersonationExit: () {
                unawaited(_boot());
              },
            ),
    );
  }
}
