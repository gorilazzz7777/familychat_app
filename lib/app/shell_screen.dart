import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../core/call/callkit_incoming_service.dart';
import '../core/notifications/familychat_notifications.dart';
import '../core/platform/web_visibility_presence.dart';
import '../core/presence/user_presence_cache.dart';
import '../core/push/push_navigation.dart';
import '../core/push/push_registration_service.dart';
import '../core/push/web_push_bridge.dart';
import '../core/services/rustore_review_prompt_service.dart';
import '../core/updates/app_update_service.dart';
import '../core/widgets/app_skeletons.dart';
import '../core/widgets/family_app_bar.dart';
import '../core/widgets/impersonation_banner.dart';
import '../core/providers/app_providers.dart';
import '../core/theme/theme_seed_controller.dart';
import '../core/share/incoming_share_bus.dart';
import '../core/share/share_direct_target_service.dart';
import '../core/settings/app_settings_controller.dart';
import '../core/settings/shell_nav_layout.dart';
import 'app_actions_scope.dart';
import 'shell_nav_bar.dart';
import 'shell_refresh.dart';
import '../features/calendar/data/calendar_photo_sync_service.dart';
import '../features/calendar/presentation/calendar_staging_review_screen.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/chat/data/active_chat_context.dart';
import '../features/chat/data/chat_unread_providers.dart';
import '../features/chat/data/familychat_presence_service.dart';
import '../features/chat/data/familychat_realtime.dart';
import '../features/chat/presentation/chat_hub_screen.dart';
import '../features/chat/data/chat_offline_prefetch.dart';
import '../features/chat/data/chat_offline_sync.dart';
import '../features/chat/data/chat_scheduled_send_service.dart';
import '../features/chat/data/chat_voice_transcription_prefs.dart';
import '../features/chat/data/incoming_call_coordinator.dart';
import '../features/chat/presentation/chat_share_target_screen.dart';
import '../core/media/gallery_media_utils.dart';
import '../features/chat/presentation/widgets/chat_attach_sheet/chat_attach_sheet.dart';
import '../features/feed/data/feed_post_target.dart';
import '../features/feed/data/feed_post_uploader.dart';
import '../features/feed/presentation/feed_screen.dart';
import '../features/feed/presentation/feed_post_compose_screen.dart';
import '../features/gallery/presentation/gallery_menu_screen.dart';
import '../features/location/data/location_share_coordinator.dart';
import '../features/location/presentation/family_map_screen.dart';
import '../features/members/presentation/family_invite_flow.dart';
import '../features/members/presentation/members_screen.dart';

class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({
    super.key,
    required this.status,
    required this.onLogout,
    required this.onStatusChanged,
    this.onImpersonationExit,
  });

  final Map<String, dynamic> status;
  final Future<void> Function() onLogout;
  final Future<void> Function() onStatusChanged;
  final VoidCallback? onImpersonationExit;

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen>
    with WidgetsBindingObserver {
  static const _chatTabIndex = 0;
  static const _feedTabIndex = 1;
  static const _familyTabIndex = 2;
  static const _galleryTabIndex = 3;
  static const _calendarTabIndex = 4;
  static const _tabRefreshTtl = Duration(seconds: 45);

  int _index = _chatTabIndex;
  late Map<String, dynamic> _status;
  final _feedKey = GlobalKey<FeedScreenState>();
  final _chatHubKey = GlobalKey<ChatHubScreenState>();
  final _galleryMenuKey = GlobalKey<State<GalleryMenuScreen>>();
  final _tabRefreshedAt = <int, DateTime>{};
  /// Чат (главная) + лента сразу; остальные — при первом заходе.
  final _visitedTabs = <int>{_chatTabIndex, _feedTabIndex};
  Timer? _webPollTimer;
  Timer? _presenceTimer;
  bool _lastKnownOnline = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _status = widget.status;
    IncomingShareBus.instance.addListener(_onIncomingShare);
    onOpenFeedFromPush = _openFeedFromPush;
    if (kIsWeb) {
      _webPollTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        unawaited(_webRealtimeSoftSync());
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      flushPendingChatPush();
      IncomingCallCoordinator.instance.flushPendingIfAny();
      unawaited(CallKitIncomingService.reconcileActiveCalls());
      unawaited(FamilyChatNotifications.consumeLaunchNotification());
      unawaited(FamilyChatNotifications.clearMessageNotificationsOnAppOpen());
      unawaited(ShareDirectTargetService.syncFromStore());
      _openPendingShareIfAny();
      final userId = _currentUserId;
      if (userId != null) {
        unawaited(
          _runCalendarSyncAndMaybeReview(userId),
        );
      }
      unawaited(
        ChatOfflineSync.instance.run(ref.read(familychatRepositoryProvider)),
      );
      unawaited(
        ChatOfflinePrefetch.scheduleSecondary(
          ref.read(familychatRepositoryProvider),
          currentUserId: _currentUserId,
        ),
      );
      // Распаковка Vosk RU из assets (без интернета).
      ref.read(voskModelPreloadProvider);
      ChatScheduledSendService.instance.start(
        ref.read(familychatRepositoryProvider),
      );
      unawaited(
        RuStoreReviewPromptService.onAppSessionOpened(
          context,
          repository: ref.read(familychatRepositoryProvider),
          fromColdStart: true,
        ),
      );
      unawaited(AppUpdateService.checkAndPrompt(context));
      unawaited(ref.read(appSettingsProvider.notifier).syncFromServer());
      LocationShareCoordinator.instance.attach(
        ref.read(familychatRepositoryProvider),
      );
    });
    FamilyChatRealtime.instance.addListener(_onChatRealtime);
    ChatUnreadRefresh.onInvalidate = _onUnreadInvalidate;
    ChatOfflineSync.instance.addListener(_onOfflineStateChanged);
    _lastKnownOnline = ChatOfflineSync.instance.isOnline;
    ShellRefresh.instance.register(_refreshMainTabs);
    _startPresenceHeartbeat();
    installWebVisibilityPresenceListener();
    AppActions.bindShell(selectSection: _selectSection);
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

  Future<void> _runCalendarSyncAndMaybeReview(int userId) async {
    final repo = ref.read(familychatRepositoryProvider);
    await runActiveAndroidCalendarSync(repo: repo, userId: userId);
    if (!mounted) return;
    final service = CalendarPhotoSyncService(repo);
    if (!await service.shouldShowDailyReviewPrompt()) return;
    List<CalendarPhotoSyncInfo> pending;
    try {
      pending = await service.fetchPendingReviews();
    } catch (_) {
      return;
    }
    if (!mounted || pending.isEmpty) return;
    await service.markDailyReviewPromptShown();
    if (!mounted) return;
    final first = pending.first;
    final total = pending.fold<int>(0, (s, e) => s + e.pendingReviewCount);
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новые фото события'),
        content: Text(
          pending.length == 1
              ? 'Собрали $total фото для «${first.title}». '
                  'Проверьте перед добавлением в общий альбом.'
              : 'Собрали $total фото по ${pending.length} событиям. '
                  'Проверьте перед добавлением в общие альбомы.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Позже'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Проверить'),
          ),
        ],
      ),
    );
    if (open != true || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarStagingReviewScreen(info: first),
      ),
    );
  }

  Future<void> _refreshMainTabs({bool silent = true}) async {
    await _refreshTab(_chatTabIndex, silent: silent);
    await _refreshTab(_feedTabIndex, silent: silent);
    await _refreshTab(_familyTabIndex, silent: silent);
  }

  void _onUnreadInvalidate() {
    if (!mounted) return;
    ref.invalidate(chatUnreadTotalProvider);
  }

  void _onChatRealtime(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev == 'ws_connected') {
      FamilyChatPresenceService.onRealtimeConnected();
      return;
    }
    if (ev == 'user_presence') {
      UserPresenceCache.instance.applyEvent(event);
      return;
    }
    // Unread badge: invalidate only after SQLite writes (ChatSyncService /
    // hub watch). Premature invalidate races a stale FutureProvider read.
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
      final callerName = event['caller_name']?.toString() ?? 'Family Space';
      IncomingCallCoordinator.instance.present(
        callId: callId,
        threadId: threadId,
        callerUserId: callerUserId,
        callerName: callerName,
        isVideo: IncomingCallCoordinator.parseIsVideo(event['is_video']),
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
    final online = ChatOfflineSync.instance.isOnline;
    final becameOnline = online && !_lastKnownOnline;
    _lastKnownOnline = online;
    if (becameOnline) {
      unawaited(_refreshTab(_index, silent: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webPollTimer?.cancel();
    _presenceTimer?.cancel();
    IncomingShareBus.instance.removeListener(_onIncomingShare);
    onOpenFeedFromPush = null;
    FamilyChatRealtime.instance.removeListener(_onChatRealtime);
    if (identical(ChatUnreadRefresh.onInvalidate, _onUnreadInvalidate)) {
      ChatUnreadRefresh.onInvalidate = null;
    }
    ChatOfflineSync.instance.removeListener(_onOfflineStateChanged);
    ChatScheduledSendService.instance.stop();
    LocationShareCoordinator.instance.detach();
    ShellRefresh.instance.unregister();
    AppActions.clearShell();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    FamilyChatPresenceService.onLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      IncomingCallCoordinator.instance.flushPendingIfAny();
      unawaited(CallKitIncomingService.reconcileActiveCalls());
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
        unawaited(_runCalendarSyncAndMaybeReview(userId));
      }
      unawaited(
        RuStoreReviewPromptService.onAppSessionOpened(
          context,
          repository: ref.read(familychatRepositoryProvider),
        ),
      );
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        RuStoreReviewPromptService.onAppPaused();
      }
      unawaited(_reportAppBackground());
    }
  }

  Future<void> _reportAppBackground() async {
    FamilyChatPresenceService.syncNow();
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
    final directThreadId =
        await ShareDirectTargetService.takePendingDirectShareThreadId();
    final sent = await familyChatNavigatorKey.currentState?.push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ChatShareTargetScreen(
          media: media,
          directShareThreadId: directThreadId,
        ),
      ),
    );
    if (!mounted) return;
    if (sent == true) {
      await _refreshTab(_chatTabIndex, silent: true);
      await _refreshTab(_feedTabIndex, silent: true);
    }
    // Share flow can race with cold-start push pending navigation.
    flushPendingChatPush();
  }

  Future<void> _refreshTab(int tabIndex, {bool silent = true}) async {
    switch (tabIndex) {
      case _chatTabIndex:
        await _chatHubKey.currentState?.refresh(silent: silent);
      case _feedTabIndex:
        await _feedKey.currentState?.refresh(silent: silent);
      default:
        break;
    }
    _tabRefreshedAt[tabIndex] = DateTime.now();
  }

  bool _shouldRefreshTab(int tabIndex) {
    final last = _tabRefreshedAt[tabIndex];
    if (last == null) return true;
    return DateTime.now().difference(last) > _tabRefreshTtl;
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

  bool get _hasIndividualPremium {
    final entitlements = _status['entitlements'];
    return entitlements is Map && entitlements['individual_premium'] == true;
  }

  String get _title => switch (_index) {
        _chatTabIndex => 'Family Space',
        _feedTabIndex => 'Лента',
        _familyTabIndex => 'Семья',
        _galleryTabIndex => 'Галерея',
        _calendarTabIndex => 'Календарь',
        _ => 'Family Space',
      };

  bool get _hideShellAppBar =>
      _index == _chatTabIndex ||
      _index == _galleryTabIndex ||
      _index == _calendarTabIndex;

  void _selectSection(ShellSection section) {
    final i = _indexOf(section);
    final previous = _index;
    final needsBuild = !_visitedTabs.contains(i);
    setState(() {
      _index = i;
      if (needsBuild) _visitedTabs.add(i);
    });
    if (previous != i && _shouldRefreshTab(i)) {
      unawaited(_refreshTab(i, silent: true));
    }
  }

  void _openFeedFromPush() {
    if (!mounted) return;
    final layout = ShellNavLayout.fromSettings(ref.read(appSettingsProvider));
    if (!layout.isEnabled(ShellSection.feed)) return;
    _selectSection(ShellSection.feed);
    unawaited(_refreshTab(_feedTabIndex, silent: true));
  }

  int _indexOf(ShellSection section) {
    return switch (section) {
      ShellSection.chat => _chatTabIndex,
      ShellSection.feed => _feedTabIndex,
      ShellSection.family => _familyTabIndex,
      ShellSection.gallery => _galleryTabIndex,
      ShellSection.calendar => _calendarTabIndex,
    };
  }

  ShellSection _sectionOf(int index) {
    return switch (index) {
      _feedTabIndex => ShellSection.feed,
      _familyTabIndex => ShellSection.family,
      _galleryTabIndex => ShellSection.gallery,
      _calendarTabIndex => ShellSection.calendar,
      _ => ShellSection.chat,
    };
  }

  void _onBarDestinationSelected(int i, ShellNavLayout layout) {
    if (layout.showMore && i == layout.barSections.length) {
      unawaited(_openMoreSheet(layout));
      return;
    }
    if (i < 0 || i >= layout.barSections.length) return;
    _selectSection(layout.barSections[i]);
  }

  Future<void> _openMoreSheet(ShellNavLayout layout) async {
    final picked = await showModalBottomSheet<ShellSection>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Ещё')),
              for (final section in layout.overflowSections)
                ListTile(
                  leading: Icon(ShellNavLayout.icon(section)),
                  title: Text(ShellNavLayout.label(section)),
                  onTap: () => Navigator.pop(ctx, section),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    _selectSection(picked);
  }

  Widget _buildTab(int i) {
    if (!_visitedTabs.contains(i)) {
      return const SizedBox.shrink();
    }
    final userId = _currentUserId;
    switch (i) {
      case _chatTabIndex:
        return ChatHubScreen(
          key: _chatHubKey,
          hasIndividualPremium: _hasIndividualPremium,
          profileName: _displayName,
          profileAvatarUrl: _avatarUrl,
          onProfileTap: _openProfile,
        );
      case _feedTabIndex:
        return FeedScreen(key: _feedKey);
      case _familyTabIndex:
        return MembersScreen(
          currentUserId: userId,
          onOpenOwnProfile: _openProfile,
          showAppBar: false,
        );
      case _galleryTabIndex:
        return userId == null
            ? const DeferredPlaceholder(
                child: Center(child: CircularProgressIndicator()),
              )
            : GalleryMenuScreen(
                key: _galleryMenuKey,
                currentUserId: userId,
              );
      case _calendarTabIndex:
        return const CalendarScreen();
      default:
        return const SizedBox.shrink();
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

  Future<void> _openFeedPost(FeedPostTarget target) async {
    final userId = _currentUserId;
    if (userId == null) return;

    final childTarget = target is FeedPostTargetChild ? target : null;
    if (!mounted) return;

    Future<void> openCompose(List<FeedPostPhoto> photos) async {
      if (photos.isEmpty || !mounted) return;
      final posted = await Navigator.of(context).push<Object?>(
        MaterialPageRoute<Object?>(
          builder: (_) => FeedPostComposeScreen(
            initialPhotos: photos,
            target: target,
          ),
        ),
      );
      if (!mounted) return;
      if (posted is Map<String, dynamic>) {
        _feedKey.currentState?.prependOptimisticEvent(posted);
        return;
      }
      if (posted == true) {
        await _refreshTab(_feedTabIndex, silent: true);
      }
    }

    await ChatAttachSheet.show(
      context,
      style: ChatAttachSheetStyle.albumMedia,
      familyGalleryUserId: userId,
      familyGalleryChildId: childTarget?.childId,
      familyGalleryChildName: childTarget?.displayName,
      onSendMedia: (_, items) async {
        if (items.isEmpty || !mounted) return;
        final raw = <FeedPostPhoto>[];
        for (final item in items) {
          if (item.kind != 'image' && item.kind != 'video') continue;
          raw.add(
            FeedPostPhoto(
              bytes: item.bytes,
              filename: item.filename,
              contentType:
                  item.contentType ?? contentTypeForFilename(item.filename),
              kind: item.kind,
              localPath: item.localPath,
              thumbnailBytes: item.thumbnailBytes,
              cacheId: item.id,
            ),
          );
        }
        final photos = await FeedPostUploader.normalizePhotos(raw);
        await openCompose(photos);
      },
      onAddFromFamilyGallery: (ids) async {
        if (ids.isEmpty || !mounted) return;
        final repo = ref.read(familychatRepositoryProvider);
        final wanted = ids.toSet();
        final found = <int, Map<String, dynamic>>{};
        var offset = 0;
        while (found.length < wanted.length && offset < 600) {
          final data = await repo.memberGalleryPickablePhotos(
            userId,
            offset: offset,
            limit: 60,
          );
          final batch = (data['photos'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          if (batch.isEmpty) break;
          for (final photo in batch) {
            final id = photo['id'];
            final aid = id is int ? id : int.tryParse('$id');
            if (aid != null && wanted.contains(aid)) {
              found[aid] = photo;
            }
          }
          offset += batch.length;
          final total = data['total'] is int
              ? data['total'] as int
              : int.tryParse('${data['total']}') ?? 0;
          if (offset >= total) break;
        }

        final raw = <FeedPostPhoto>[];
        for (final id in ids) {
          if (raw.length >= FeedPostUploader.maxPhotos) break;
          final meta = found[id];
          if (meta == null) continue;
          final threadId = meta['thread_id'] is int
              ? meta['thread_id'] as int
              : int.tryParse('${meta['thread_id']}');
          if (threadId == null) continue;
          try {
            final bytes = await repo.fetchChatAttachmentBytes(threadId, id);
            if (bytes.isEmpty) continue;
            final filename = meta['filename']?.toString() ?? 'photo_$id.jpg';
            final kind =
                meta['kind']?.toString() == 'video' ? 'video' : 'image';
            raw.add(
              FeedPostPhoto(
                bytes: bytes,
                filename: filename,
                contentType: meta['content_type']?.toString() ??
                    contentTypeForFilename(filename),
                kind: kind,
                cacheId: 'gallery_$id',
              ),
            );
          } catch (_) {}
        }
        final photos = await FeedPostUploader.normalizePhotos(raw);
        await openCompose(photos);
      },
    );
  }

  Future<void> _openProfile() async {
    await AppActions.openProfile(context);
    if (!mounted) return;
    await _handleStatusChanged();
  }

  @override
  Widget build(BuildContext context) {
    final showingNestedScreen = _hideShellAppBar;
    final layout = ShellNavLayout.fromSettings(ref.watch(appSettingsProvider));
    final current = _sectionOf(_index);
    if (!layout.isEnabled(current) && _index != _chatTabIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!layout.isEnabled(_sectionOf(_index))) {
          _selectSection(ShellSection.chat);
        }
      });
    }
    final barIndex = layout.barSections.indexOf(current);
    final selectedIndex = barIndex >= 0
        ? barIndex
        : (layout.showMore ? layout.barSections.length : 0);

    return Scaffold(
      appBar: showingNestedScreen
          ? null
          : FamilyAppBar.build(
              title: _title,
              profileName: _displayName,
              profileAvatarUrl: _avatarUrl,
              onProfileTap: _openProfile,
              actions: [
                if (_index == _feedTabIndex)
                  FeedPostMenuButton(
                    onTargetSelected: (target) =>
                        unawaited(_openFeedPost(target)),
                  ),
                if (_index == _familyTabIndex) ...[
                  IconButton(
                    icon: const Icon(Icons.map_outlined),
                    tooltip: 'На карте',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const FamilyMapScreen(),
                        ),
                      );
                    },
                  ),
                  FamilyAddMenuButton(
                    repo: ref.read(familychatRepositoryProvider),
                  ),
                ],
              ],
            ),
      floatingActionButton: null,
      body: Column(
        children: [
          ImpersonationBannerStrip(onSessionChanged: widget.onImpersonationExit),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: List<Widget>.generate(5, _buildTab),
            ),
          ),
        ],
      ),
      bottomNavigationBar: layout.showBar && layout.barSections.isNotEmpty
          ? _ShellNavBarWithUnread(
              layout: layout,
              selectedIndex: selectedIndex.clamp(0, layout.barSections.length),
              onDestinationSelected: (i) =>
                  _onBarDestinationSelected(i, layout),
              onBarReorder: (oldIndex, newIndex) {
                final next = ShellNavLayout.orderKeysAfterMove(
                  currentKeys: ref.read(appSettingsProvider).menuOrder,
                  enabled: layout.barSections,
                  oldIndex: oldIndex,
                  newIndex: newIndex,
                );
                unawaited(
                  ref.read(appSettingsProvider.notifier).setMenuOrder(next),
                );
              },
            )
          : null,
    );
  }
}

class _ShellNavBarWithUnread extends ConsumerWidget {
  const _ShellNavBarWithUnread({
    required this.layout,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onBarReorder,
  });

  final ShellNavLayout layout;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final void Function(int oldIndex, int newIndex) onBarReorder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadAsync = ref.watch(chatUnreadTotalProvider);
    final chatUnread = unreadAsync.when(
      data: (value) => value,
      loading: () => unreadAsync.valueOrNull ?? 0,
      error: (_, __) => 0,
    );
    final chatBadgeLabel = chatUnread > 99 ? '99+' : '$chatUnread';
    return ShellNavBar(
      layout: layout,
      selectedIndex: selectedIndex,
      chatUnread: chatUnread,
      chatBadgeLabel: chatBadgeLabel,
      onDestinationSelected: onDestinationSelected,
      onBarReorder: onBarReorder,
    );
  }
}
