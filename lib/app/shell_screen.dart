import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../core/push/push_navigation.dart';
import '../core/providers/app_providers.dart';
import '../core/share/incoming_share_bus.dart';
import '../features/calendar/data/calendar_photo_sync_service.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/chat/data/chat_unread_providers.dart';
import '../features/chat/data/familychat_realtime.dart';
import '../features/chat/presentation/chat_hub_screen.dart';
import '../features/chat/presentation/chat_share_target_screen.dart';
import '../features/feed/presentation/feed_screen.dart';
import '../features/gallery/presentation/family_gallery_tab.dart';
import '../features/members/presentation/members_screen.dart';
import '../features/more/presentation/more_menu_panel.dart';
import '../features/profile/presentation/profile_screen.dart';

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

class _ShellScreenState extends ConsumerState<ShellScreen> with WidgetsBindingObserver {
  static const _moreTabIndex = 3;

  int _index = 0;
  bool _moreMenuOpen = false;
  late Map<String, dynamic> _status;
  final _chatHubKey = GlobalKey<ChatHubScreenState>();
  Timer? _webPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _status = widget.status;
    IncomingShareBus.instance.addListener(_onIncomingShare);
    if (kIsWeb) {
      _webPollTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        FamilyChatRealtime.instance.emitSyntheticEvent({'event': 'chat_refresh'});
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      flushPendingChatPush();
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
    });
    FamilyChatRealtime.instance.addListener(_onChatRealtime);
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webPollTimer?.cancel();
    IncomingShareBus.instance.removeListener(_onIncomingShare);
    FamilyChatRealtime.instance.removeListener(_onChatRealtime);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(FamilyChatRealtime.instance.reconnectAndRefresh());
      final userId = _currentUserId;
      if (userId != null) {
        unawaited(
          runActiveAndroidCalendarSync(
            repo: ref.read(familychatRepositoryProvider),
            userId: userId,
          ),
        );
      }
    }
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
    familyChatNavigatorKey.currentState?.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatShareTargetScreen(media: media),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant ShellScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _status = widget.status;
    }
  }

  int? get _currentUserId => _status['user_id'] is int ? _status['user_id'] as int : null;

  String get _title => switch (_index) {
        0 => 'Главная',
        1 => 'Семейный чат',
        2 => 'Галерея',
        _ => 'Ещё',
      };

  void _onDestinationSelected(int i) {
    if (i == _moreTabIndex) {
      setState(() => _moreMenuOpen = !_moreMenuOpen);
      return;
    }
    setState(() {
      _index = i;
      _moreMenuOpen = false;
    });
  }

  Future<void> _handleStatusChanged() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      if (!mounted) return;
      setState(() => _status = st);
      await widget.onStatusChanged();
    } catch (_) {}
  }

  void _openFamily() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MembersScreen(
          currentUserId: _currentUserId,
          onOpenOwnProfile: _openProfile,
        ),
      ),
    );
  }

  void _openCalendar() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const CalendarScreen()),
    );
  }

  void _openProfile() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(
          status: _status,
          onLogout: widget.onLogout,
          onStatusChanged: () {
            unawaited(_handleStatusChanged());
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userId = _currentUserId;
    final navSelected = _moreMenuOpen ? _moreTabIndex : _index;
    final chatUnread = ref.watch(chatUnreadTotalProvider).value ?? 0;
    final chatBadgeLabel = chatUnread > 99 ? '99+' : '$chatUnread';

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (_index == 1) ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Поиск',
              onPressed: () => _chatHubKey.currentState?.toggleSearch(),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Создать группу',
              onPressed: () => _chatHubKey.currentState?.createGroup(),
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          IndexedStack(
            index: _index,
            children: [
              const FeedScreen(),
              ChatHubScreen(key: _chatHubKey),
              userId == null
                  ? const Center(child: CircularProgressIndicator())
                  : FamilyGalleryTab(currentUserId: userId),
              const SizedBox.shrink(),
            ],
          ),
          if (_moreMenuOpen)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _moreMenuOpen = false),
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
              ),
            ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _moreMenuOpen
                ? MoreMenuPanel(
                    onClose: () => setState(() => _moreMenuOpen = false),
                    onOpenFamily: _openFamily,
                    onOpenCalendar: _openCalendar,
                    onOpenProfile: _openProfile,
                  )
                : const SizedBox.shrink(),
          ),
          NavigationBar(
            selectedIndex: navSelected,
            onDestinationSelected: _onDestinationSelected,
            destinations: [
              const NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Главная'),
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
              const NavigationDestination(icon: Icon(Icons.photo_library_outlined), label: 'Галерея'),
              const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Ещё'),
            ],
          ),
        ],
      ),
    );
  }
}
