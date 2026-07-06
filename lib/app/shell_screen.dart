import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/config/env.dart';
import '../core/providers/app_providers.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/chat/presentation/chat_hub_screen.dart';
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

class _ShellScreenState extends ConsumerState<ShellScreen> {
  int _index = 0;
  late Map<String, dynamic> _status;

  @override
  void initState() {
    super.initState();
    _status = widget.status;
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
          const ChatHubScreen(),
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
