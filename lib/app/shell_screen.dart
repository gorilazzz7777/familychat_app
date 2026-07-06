import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../core/config/env.dart';
import '../core/push/push_navigation.dart';
import '../core/providers/app_providers.dart';
import '../core/share/incoming_share_bus.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/chat/data/familychat_realtime.dart';
import '../features/chat/presentation/chat_hub_screen.dart';
import '../features/chat/presentation/chat_share_target_screen.dart';
import '../features/members/presentation/invite_kinship_dialog.dart';
import '../features/members/presentation/members_screen.dart';
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
  int _index = 0;
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
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webPollTimer?.cancel();
    IncomingShareBus.instance.removeListener(_onIncomingShare);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(FamilyChatRealtime.instance.reconnectAndRefresh());
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

  String get _title => switch (_index) {
        0 => 'Семейный чат',
        1 => 'Семья',
        2 => 'Календарь',
        _ => 'Профиль',
      };

  Future<void> _inviteMember() async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final options = await repo.kinshipOptions();
      if (!mounted) return;
      final code = await showInviteKinshipDialog(context, options: options);
      if (code == null || !mounted) return;
      final inv = await repo.createInvite(code);
      final url = inv['invite_url'] as String? ??
          '${Env.inviteBaseUrl}${inv['invite_url_path']}';
      await Share.share('Приглашение в Family Chat: $url');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать приглашение: $e')),
      );
    }
  }

  Future<void> _handleStatusChanged() async {
    try {
      final st = await ref.read(familychatRepositoryProvider).status();
      if (!mounted) return;
      setState(() => _status = st);
      await widget.onStatusChanged();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (_index == 0) ...[
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
          if (_index == 1)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Пригласить',
              onPressed: _inviteMember,
            ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          ChatHubScreen(key: _chatHubKey),
          MembersScreen(
            currentUserId: _status['user_id'] as int?,
            onOpenOwnProfile: () => setState(() => _index = 3),
          ),
          const CalendarScreen(),
          ProfileScreen(
            status: _status,
            onLogout: widget.onLogout,
            onStatusChanged: () {
              unawaited(_handleStatusChanged());
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_outlined), label: 'Чат'),
          NavigationDestination(icon: Icon(Icons.people_outline), label: 'Семья'),
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), label: 'Календарь'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Профиль'),
        ],
      ),
    );
  }
}
