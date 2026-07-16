import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../core/notifications/familychat_notifications.dart';
import '../core/push/push_navigation.dart';
import '../core/push/push_registration_service.dart';
import '../core/push/web_push_bridge.dart';
import '../core/widgets/family_app_bar.dart';
import '../core/providers/app_providers.dart';
import '../core/theme/theme_seed_controller.dart';
import '../core/share/incoming_share_bus.dart';
import 'app_actions_scope.dart';
import 'shell_refresh.dart';
import '../features/calendar/data/calendar_photo_sync_service.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/chat/data/active_chat_context.dart';
import '../features/chat/data/chat_unread_providers.dart';
import '../features/chat/data/familychat_realtime.dart';
import '../features/chat/presentation/chat_hub_screen.dart';
import '../features/chat/data/chat_offline_sync.dart';
import '../features/chat/data/chat_scheduled_send_service.dart';
import '../features/chat/data/chat_voice_transcription_prefs.dart';
import '../features/chat/data/incoming_call_coordinator.dart';
import '../features/chat/presentation/chat_share_target_screen.dart';
import '../features/feed/presentation/feed_screen.dart';
import '../features/feed/presentation/feed_post_compose_screen.dart';
import '../features/gallery/presentation/gallery_menu_screen.dart';
import '../features/members/presentation/family_invite_flow.dart';
import '../features/members/presentation/members_screen.dart';

class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({
    super.key,
    required this.status,
    required this.onLogout,
    required this.onStatusChanged,
  });

  final Map<String, dynamic> status;
  final Future<void> Function() onLogout;
  final Future<void> Function() onStatusChanged;

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen>
    with WidgetsBindingObserver {
  static const _galleryTabIndex = 3;
  static const _calendarTabIndex = 4;

  int _index = 0;
  late Map<String, dynamic> _status;
  final _feedKey = GlobalKey<FeedScreenState>();
  final _chatHubKey = GlobalKey<ChatHubScreenState>();
  Timer? _webPollTimer;
  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _status = widget.status;
    IncomingShareBus.instance.addListener(_onIncomingShare);
    if (kIsWeb) {
      _webPollTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        unawaited(_webRealtimeSoftSync());
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      flushPendingChatPush();
      IncomingCallCoordinator.instance.flushPendingIfAny();
      unawaited(FamilyChatNotifications.consumeLaunchNotification());
      unawaited(FamilyChatNotifications.clearMessageNotificationsOnAppOpen());
      _openPendingShareIfAny();
      final userId = _currentUserId;
      if (userId != null) {
        unawaited(
          runActiveAndroidCalendarSync(
            repo: ref.read(familychatRepositoryProvider),
            userId: userId,
          ),
        );
      }
      unawaited(
        ChatOfflineSync.instance.run(ref.read(familychatRepositoryProvider)),
      );
      // Распаковка Vosk RU из assets (без интернета).
      ref.read(voskModelPreloadProvider);
      ChatScheduledSendService.instance.start(
        ref.read(familychatRepositoryProvider),
      );
    });
    FamilyChatRealtime.instance.addListener(_onChatRealtime);
    ChatOfflineSync.instance.addListener(_onOfflineStateChanged);
    ShellRefresh.instance.register(_refreshMainTabs);
    _startPresenceHeartbeat();
  }

  void _startPresenceHeartbeat() {
    _presenceTimer?.cancel();
    unawaited(_touchPresence());
    _presenceTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(_touchPresence());
    });
  }

  Future<void> _webRealtimeSoftSync() async {
    final realtime = FamilyChatRealtime.instance;
    if (!realtime.isConnected) {
      await realtime.reconnectAndRefresh();
      return;
    }
    final threadId = ActiveChatContext.instance.openThreadId;
    realtime.emitSyntheticEvent({
      'event': 'chat_refresh',
      if (threadId != null) 'thread_id': threadId,
    });
  }

  Future<void> _touchPresence() async {
    await ChatOfflineSync.instance.refreshOnline(
      ref.read(familychatRepositoryProvider),
    );
  }

  Future<void> _refreshMainTabs({bool silent = true}) async {
    await _refreshTab(0, silent: silent);
    await _refreshTab(1, silent: silent);
    await _refreshTab(2, silent: silent);
  }

  void _onChatRealtime(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev == 'chat_message' ||
        ev == 'chat_messages_read' ||
        ev == 'chat_refresh' ||
        ev == 'chat_messages_deleted' ||
        ev == 'chat_message_reactions') {
      invalidateChatUnreadTotal(ref);
    }
    if (ev == 'chat_call_incoming') {
      final callId = event['session_id'] is int
          ? event['session_id'] as int
          : int.tryParse('${event['session_id']}');
      final threadId = event['thread_id'] is int
          ? event['thread_id'] as int
          : int.tryParse('${event['thread_id']}');
      if (callId == null || threadId == null) return;
      final callerUserId = event['caller_user_id'] is int
          ? event['caller_user_id'] as int
          : int.tryParse('${event['caller_user_id']}') ?? 0;
      final callerName = event['caller_name']?.toString() ?? 'Family Chat';
      IncomingCallCoordinator.instance.present(
        callId: callId,
        threadId: threadId,
        callerUserId: callerUserId,
        callerName: callerName,
      );
      return;
    }
    if (ev == 'chat_call_state') {
      final status = event['status']?.toString() ?? '';
      final callId = event['session_id'] is int
          ? event['session_id'] as int
          : int.tryParse('${event['session_id']}');
      if (callId != null && status.isNotEmpty && status != 'ringing') {
        unawaited(stopServiceWorkerCallRing(callId));
      }
    }
  }

  void _onOfflineStateChanged() {
    if (!mounted) return;
    setState(() {});
    if (ChatOfflineSync.instance.isOnline) {
      unawaited(_refreshTab(_index, silent: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webPollTimer?.cancel();
    _presenceTimer?.cancel();
    IncomingShareBus.instance.removeListener(_onIncomingShare);
    FamilyChatRealtime.instance.removeListener(_onChatRealtime);
    ChatOfflineSync.instance.removeListener(_onOfflineStateChanged);
    ChatScheduledSendService.instance.stop();
    ShellRefresh.instance.unregister();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      IncomingCallCoordinator.instance.flushPendingIfAny();
      unawaited(FamilyChatNotifications.consumeLaunchNotification());
      unawaited(FamilyChatNotifications.clearMessageNotificationsOnAppOpen());
      unawaited(FamilyChatRealtime.instance.reconnectAndRefresh());
      unawaited(_refreshTab(_index, silent: true));
      unawaited(_touchPresence());
      unawaited(
        PushRegistrationService.registerIfPossible(
          client: ref.read(apiClientProvider),
          repository: ref.read(familychatRepositoryProvider),
        ),
      );
      unawaited(
        ChatOfflineSync.instance.run(ref.read(familychatRepositoryProvider)),
      );
      unawaited(ChatScheduledSendService.instance.dispatchDue());
      final userId = _currentUserId;
      if (userId != null) {
        unawaited(
          runActiveAndroidCalendarSync(
            repo: ref.read(familychatRepositoryProvider),
            userId: userId,
          ),
        );
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_reportAppBackground());
    }
  }

  Future<void> _reportAppBackground() async {
    try {
      await ref
          .read(familychatRepositoryProvider)
          .status(appForeground: false);
    } catch (_) {}
  }

  void _onIncomingShare() {
    _openPendingShareIfAny();
  }

  void _openPendingShareIfAny() {
    if (!IncomingShareBus.instance.hasPending) return;
    final nav = familyChatNavigatorKey.currentState;
    if (nav == null) return;
    final media = IncomingShareBus.instance.takePending();
    if (media == null) return;
    _openShareScreen(media);
  }

  void _openShareScreen(SharedMedia media) {
    unawaited(_openShareScreenAndRefresh(media));
  }

  Future<void> _openShareScreenAndRefresh(SharedMedia media) async {
    final sent = await familyChatNavigatorKey.currentState?.push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ChatShareTargetScreen(media: media),
      ),
    );
    if (!mounted) return;
    if (sent == true) {
      await _refreshTab(0, silent: true);
      await _refreshTab(1, silent: true);
    }
  }

  Future<void> _refreshTab(int tabIndex, {bool silent = true}) async {
    switch (tabIndex) {
      case 0:
        await _feedKey.currentState?.refresh(silent: silent);
      case 1:
        await _chatHubKey.currentState?.refresh(silent: silent);
      default:
        break;
    }
  }

  @override
  void didUpdateWidget(covariant ShellScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _status = widget.status;
    }
  }

  int? get _currentUserId =>
      _status['user_id'] is int ? _status['user_id'] as int : null;

  String get _displayName => _status['display_name']?.toString() ?? '';
  String get _avatarUrl => _status['avatar_url']?.toString() ?? '';

  String get _title => switch (_index) {
        0 => 'Главная',
        1 => 'Семейный чат',
        2 => 'Семья',
        3 => 'Галерея',
        4 => 'Календарь',
        _ => 'Family Chat',
      };

  bool get _hideShellAppBar =>
      _index == _galleryTabIndex || _index == _calendarTabIndex;

  void _onDestinationSelected(int i) {
    final previous = _index;
    setState(() => _index = i);
    if (previous != i) {
      unawaited(_refreshTab(i, silent: true));
    }
  }

  Future<void> _handleStatusChanged() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      await ref.read(themeSeedProvider.notifier).syncFromStatus(st);
      if (!mounted) return;
      setState(() => _status = st);
      await widget.onStatusChanged();
    } catch (_) {}
  }

  Future<void> _openProfile() async {
    await AppActions.openProfile(context);
    if (!mounted) return;
    await _handleStatusChanged();
  }

  Future<void> _openFeedPost() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const FeedPostComposeScreen(),
      ),
    );
    if (!mounted || posted != true) return;
    await _refreshTab(0, silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final userId = _currentUserId;
    final chatUnread = ref.watch(chatUnreadTotalProvider).value ?? 0;
    final chatBadgeLabel = chatUnread > 99 ? '99+' : '$chatUnread';
    final showingNestedScreen = _hideShellAppBar;

    return Scaffold(
      appBar: showingNestedScreen
          ? null
          : FamilyAppBar.build(
              title: _title,
              profileName: _displayName,
              profileAvatarUrl: _avatarUrl,
              onProfileTap: _openProfile,
              actions: [
                if (_index == 1) ...[
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Поиск',
                    onPressed: () => _chatHubKey.currentState?.toggleSearch(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Создать',
                    onPressed: () {
                      final entitlements =
                          widget.status['entitlements'] as Map?;
                      final premium =
                          entitlements?['individual_premium'] == true;
                      _chatHubKey.currentState?.openCreateMenu(
                        hasIndividualPremium: premium,
                      );
                    },
                  ),
                ],
                if (_index == 2)
                  IconButton(
                    icon: const Icon(Icons.person_add_outlined),
                    tooltip: 'Добавить в семью',
                    onPressed: () => runFamilyInviteFlow(
                      context,
                      ref.read(familychatRepositoryProvider),
                    ),
                  ),
              ],
            ),
      floatingActionButton: _index == 0 && !showingNestedScreen
          ? FloatingActionButton(
              onPressed: _openFeedPost,
              tooltip: 'В ленту',
              child: const Icon(Icons.add),
            )
          : null,
      body: IndexedStack(
        index: _index,
        children: [
          FeedScreen(key: _feedKey),
          ChatHubScreen(key: _chatHubKey),
          MembersScreen(
            currentUserId: _currentUserId,
            onOpenOwnProfile: _openProfile,
            showAppBar: false,
          ),
          userId == null
              ? const Center(child: CircularProgressIndicator())
              : GalleryMenuScreen(currentUserId: userId),
          const CalendarScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onDestinationSelected,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: chatUnread > 0,
              label: Text(chatBadgeLabel),
              child: const Icon(Icons.chat_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: chatUnread > 0,
              label: Text(chatBadgeLabel),
              child: const Icon(Icons.chat),
            ),
            label: 'Чат',
          ),
          const NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Семья',
          ),
          const NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: 'Галерея',
          ),
          const NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Календарь',
          ),
        ],
      ),
    );
  }
}
