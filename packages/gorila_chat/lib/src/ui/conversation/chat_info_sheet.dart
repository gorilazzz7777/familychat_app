import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../contract/chat_call_repository.dart';
import '../../contract/chat_capabilities.dart';
import '../../contract/chat_repository.dart';
import '../../realtime/gorila_chat_realtime.dart';
import '../calls/chat_call_screen.dart';
import '../widgets/chat_avatar.dart';

class ChatInfoSheet extends StatefulWidget {
  const ChatInfoSheet({
    super.key,
    required this.threadId,
    required this.title,
    required this.kind,
    required this.repository,
    required this.realtime,
    required this.capabilities,
    this.callRepository,
    this.peerUserId,
    this.peerName,
    this.peerAvatarUrl,
    this.myUserId,
    this.initialNotificationsEnabled = true,
    this.onNotificationsChanged,
  });

  final int threadId;
  final String title;
  final String kind;
  final ChatRepository repository;
  final GorilaChatRealtime realtime;
  final ChatCapabilities capabilities;
  final ChatCallRepository? callRepository;
  final int? peerUserId;
  final String? peerName;
  final String? peerAvatarUrl;
  final int? myUserId;
  final bool initialNotificationsEnabled;
  final ValueChanged<bool>? onNotificationsChanged;

  @override
  State<ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends State<ChatInfoSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Map<String, dynamic>> _media = [];
  List<Map<String, dynamic>> _links = [];
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _notificationsEnabled = true;
  bool _notificationsBusy = false;

  bool get _isDm => widget.kind == 'dm' && widget.peerUserId != null;

  @override
  void initState() {
    super.initState();
    _notificationsEnabled = widget.initialNotificationsEnabled;
    _tabs = TabController(length: _isDm ? 2 : 3, vsync: this);
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.repository.threadMedia(widget.threadId),
        widget.repository.threadLinks(widget.threadId),
        if (!_isDm)
          widget.repository.threadMembers(widget.threadId)
        else
          Future.value(<Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _media = List<Map<String, dynamic>>.from(results[0]);
        _links = List<Map<String, dynamic>>.from(results[1]);
        _members = _isDm
            ? <Map<String, dynamic>>[]
            : List<Map<String, dynamic>>.from(results[2]);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleNotifications() async {
    if (_notificationsBusy) return;
    final next = !_notificationsEnabled;
    setState(() => _notificationsBusy = true);
    try {
      final enabled = await widget.repository.setNotificationsEnabled(
        threadId: widget.threadId,
        enabled: next,
        kind: widget.kind,
        peerUserId: widget.peerUserId,
      );
      if (!mounted) return;
      setState(() => _notificationsEnabled = enabled);
      widget.onNotificationsChanged?.call(enabled);
    } finally {
      if (mounted) setState(() => _notificationsBusy = false);
    }
  }

  void _startCall() {
    final calls = widget.callRepository;
    if (!_isDm || calls == null || !widget.capabilities.supportsCalls) return;
    Navigator.of(context).pop();
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatCallScreen(
          threadId: widget.threadId,
          title: widget.peerName ?? widget.title,
          isCaller: true,
          callRepository: calls,
          realtime: widget.realtime,
          myUserId: widget.myUserId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;

    return SafeArea(
      child: SizedBox(
        height: maxHeight,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  if (_isDm)
                    ChatAvatar(
                      name: widget.peerName ?? widget.title,
                      avatarUrl: widget.peerAvatarUrl,
                      radius: 28,
                    )
                  else
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: scheme.primary,
                      child: Icon(
                        widget.kind == 'notifications'
                            ? Icons.notifications_outlined
                            : Icons.groups,
                        color: scheme.onPrimary,
                      ),
                    ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (_isDm)
                          Text(
                            'Личный чат',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_isDm && widget.capabilities.supportsCalls)
                    IconButton(
                      tooltip: 'Позвонить',
                      onPressed: _startCall,
                      icon: const Icon(Icons.call_outlined),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Уведомления'),
              value: _notificationsEnabled,
              onChanged: _notificationsBusy
                  ? null
                  : (_) => unawaited(_toggleNotifications()),
            ),
            TabBar(
              controller: _tabs,
              tabs: [
                const Tab(text: 'Медиа'),
                const Tab(text: 'Ссылки'),
                if (!_isDm) const Tab(text: 'Участники'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabs,
                      children: [
                        _mediaGrid(),
                        _linksList(),
                        if (!_isDm) _membersList(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediaGrid() {
    if (_media.isEmpty) {
      return const Center(child: Text('Нет медиа'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: _media.length,
      itemBuilder: (context, i) {
        final m = _media[i];
        final url =
            m['file_url']?.toString() ?? m['url']?.toString() ?? '';
        if (url.isEmpty) {
          return const ColoredBox(color: Colors.black12);
        }
        return CachedNetworkImage(imageUrl: url, fit: BoxFit.cover);
      },
    );
  }

  Widget _linksList() {
    if (_links.isEmpty) {
      return const Center(child: Text('Нет ссылок'));
    }
    return ListView.builder(
      itemCount: _links.length,
      itemBuilder: (context, i) {
        final link = _links[i];
        final url = link['url']?.toString() ?? '';
        return ListTile(
          leading: const Icon(Icons.link),
          title: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: url.isEmpty
              ? null
              : () => launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  ),
        );
      },
    );
  }

  Widget _membersList() {
    if (_members.isEmpty) {
      return const Center(child: Text('Нет участников'));
    }
    return ListView.builder(
      itemCount: _members.length,
      itemBuilder: (context, i) {
        final m = _members[i];
        return ListTile(
          leading: ChatAvatar(
            name: m['display_name']?.toString() ?? '',
            avatarUrl: m['avatar_url']?.toString(),
            radius: 20,
          ),
          title: Text(m['display_name']?.toString() ?? ''),
          subtitle: Text(m['role']?.toString() ?? ''),
        );
      },
    );
  }
}
