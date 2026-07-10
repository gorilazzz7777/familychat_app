import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/presence/user_presence.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'chat_call_screen.dart';
import 'widgets/chat_network_image.dart';

String chatParticipantCountLabel(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod100 >= 11 && mod100 <= 14) return '$count участников';
  if (mod10 == 1) return '$count участник';
  if (mod10 >= 2 && mod10 <= 4) return '$count участника';
  return '$count участников';
}

typedef ChatGoToMessage = Future<void> Function(int messageId);
typedef ChatOpenImage = void Function({
  required String imageUrl,
  String? filename,
  int? messageId,
  Map<String, dynamic>? attachment,
});
typedef ChatTitleChanged = void Function(String title, String customTitle);

class ChatInfoSheet extends ConsumerStatefulWidget {
  const ChatInfoSheet({
    super.key,
    required this.threadId,
    required this.title,
    required this.defaultTitle,
    this.customTitle = '',
    this.kind = 'family',
    this.hasLeft = false,
    this.canRejoin = false,
    this.canLeave = false,
    this.participantUserIds = const [],
    this.peerUserId,
    this.onTitleChanged,
    this.onMembershipChanged,
    this.onGoToMessage,
    this.onOpenImage,
  });

  final int threadId;
  final String title;
  final String defaultTitle;
  final String customTitle;
  final String kind;
  final bool hasLeft;
  final bool canRejoin;
  final bool canLeave;
  final List<int> participantUserIds;
  final int? peerUserId;
  final ChatTitleChanged? onTitleChanged;
  final VoidCallback? onMembershipChanged;
  final ChatGoToMessage? onGoToMessage;
  final ChatOpenImage? onOpenImage;

  @override
  ConsumerState<ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends ConsumerState<ChatInfoSheet>
    with SingleTickerProviderStateMixin {
  static const _expandedHeaderHeight = 300.0;

  late final TabController _tabs;
  late String _title;
  late String _customTitle;
  List<Map<String, dynamic>> _media = [];
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _links = [];
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true;
  String? _headerAvatarUrl;
  String? _headerSubtitle;
  bool _notificationsEnabled = true;

  bool get _showParticipants =>
      (widget.kind == 'group' || widget.kind == 'family') && !widget.hasLeft;

  bool get _isDm => widget.kind == 'dm' && widget.peerUserId != null;

  int get _tabCount => _showParticipants ? 4 : 3;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _customTitle = widget.customTitle;
    _tabs = TabController(length: _tabCount, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(familychatRepositoryProvider);
    try {
      final futures = <Future<dynamic>>[
        repo.threadMedia(widget.threadId),
        repo.threadFiles(widget.threadId),
        repo.threadLinks(widget.threadId),
        repo.threadNotifications(widget.threadId),
      ];
      if (_showParticipants) {
        futures.add(repo.threadParticipants(widget.threadId));
      }
      if (widget.peerUserId != null) {
        futures.add(repo.memberProfile(widget.peerUserId!));
      }
      final results = await Future.wait(futures);
      if (!mounted) return;
      var idx = 0;
      final media = results[idx++];
      final files = results[idx++];
      final links = results[idx++];
      final notif = results[idx++] as Map<String, dynamic>;
      var participants = <Map<String, dynamic>>[];
      if (_showParticipants) {
        participants = (results[idx++] as List).cast<Map<String, dynamic>>();
      }
      Map<String, dynamic>? peerProfile;
      if (widget.peerUserId != null) {
        peerProfile = results[idx] as Map<String, dynamic>;
      }
      setState(() {
        _media = (media as List).cast<Map<String, dynamic>>();
        _files = (files as List).cast<Map<String, dynamic>>();
        _links = (links as List).cast<Map<String, dynamic>>();
        _notificationsEnabled = notif['notifications_enabled'] == true;
        if (_showParticipants) {
          _participants = participants;
        }
        if (peerProfile != null) {
          _headerAvatarUrl = peerProfile['avatar_url']?.toString();
          _headerSubtitle = userPresenceFromProfile(peerProfile).label;
        } else if (_customTitle.isNotEmpty) {
          _headerSubtitle = widget.defaultTitle;
        } else if (_showParticipants && participants.isNotEmpty) {
          _headerSubtitle = chatParticipantCountLabel(participants.length);
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshNotifications() async {
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .threadNotifications(widget.threadId);
      if (!mounted) return;
      setState(() {
        _notificationsEnabled = data['notifications_enabled'] == true;
      });
    } catch (_) {}
  }

  Future<void> _reloadParticipants() async {
    if (!_showParticipants) return;
    try {
      final list =
          await ref.read(familychatRepositoryProvider).threadParticipants(
                widget.threadId,
              );
      if (!mounted) return;
      setState(() => _participants = list);
    } catch (_) {}
  }

  Future<void> _mute(String key) async {
    try {
      await ref
          .read(familychatRepositoryProvider)
          .setThreadMute(widget.threadId, key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(key == 'off'
                ? 'Уведомления включены'
                : 'Уведомления отключены')),
      );
      await _refreshNotifications();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _renameChat() async {
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => _RenameChatDialog(
        initialTitle: _customTitle,
        defaultTitle: widget.defaultTitle,
        canReset: _customTitle.isNotEmpty,
      ),
    );
    if (!mounted || result == null) return;

    try {
      final data =
          await ref.read(familychatRepositoryProvider).setThreadCustomTitle(
                widget.threadId,
                result,
              );
      if (!mounted) return;
      final title = data['title']?.toString() ?? widget.defaultTitle;
      final customTitle = data['custom_title']?.toString() ?? '';
      setState(() {
        _title = title;
        _customTitle = customTitle;
      });
      widget.onTitleChanged?.call(title, customTitle);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            customTitle.isEmpty ? 'Название сброшено' : 'Название сохранено',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _leaveChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Покинуть чат?'),
        content: Text(
          widget.kind == 'family'
              ? 'Вы не будете получать сообщения общего чата. Вернуться можно в любой момент из списка чатов.'
              : 'Вы перестанете видеть сообщения этой группы. Вернуть вас сможет любой участник.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Покинуть')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(familychatRepositoryProvider)
          .leaveChatThread(widget.threadId);
      if (!mounted) return;
      widget.onMembershipChanged?.call();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вы покинули чат')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _rejoinChat() async {
    try {
      await ref
          .read(familychatRepositoryProvider)
          .rejoinChatThread(widget.threadId);
      if (!mounted) return;
      widget.onMembershipChanged?.call();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вы снова в общем чате семьи')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _addMembers() async {
    if (widget.kind != 'group') return;
    final members = await ref.read(familychatRepositoryProvider).members();
    final existing = _participants
        .map((p) => p['user_id'])
        .map((id) => id is int ? id : int.tryParse('$id'))
        .whereType<int>()
        .toSet();
    final status = await ref.read(familychatRepositoryProvider).status();
    final myUserId = status['user_id'] is int ? status['user_id'] as int : null;
    final candidates = members.where((m) {
      final uid = m['user_id'];
      final userId = uid is int ? uid : int.tryParse('$uid');
      if (userId == null || existing.contains(userId)) return false;
      return true;
    }).toList();
    if (!mounted) return;
    final selected = await showDialog<Set<int>>(
      context: context,
      builder: (ctx) => _AddMembersDialog(
        members: candidates,
        myUserId: myUserId,
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    try {
      await ref.read(familychatRepositoryProvider).addChatThreadMembers(
            widget.threadId,
            selected.toList(),
          );
      if (!mounted) return;
      await _reloadParticipants();
      widget.onMembershipChanged?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Добавлено: ${selected.length}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _openParticipantProfile(int userId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(userId: userId),
      ),
    );
  }

  void _startCall() {
    Navigator.of(context).pop();
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatCallScreen(
          threadId: widget.threadId,
          title: _title,
          isCaller: true,
        ),
      ),
    );
  }

  Future<void> _showMoreMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.canRejoin)
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Вернуться в чат'),
                onTap: () => Navigator.pop(ctx, 'rejoin'),
              ),
            if (widget.canLeave && !widget.hasLeft)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Покинуть чат'),
                onTap: () => Navigator.pop(ctx, 'leave'),
              ),
            if (widget.kind == 'group' && !widget.hasLeft)
              ListTile(
                leading: const Icon(Icons.person_add_outlined),
                title: const Text('Добавить участников'),
                onTap: () => Navigator.pop(ctx, 'add'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rejoin':
        await _rejoinChat();
      case 'leave':
        await _leaveChat();
      case 'add':
        await _addMembers();
    }
  }

  bool get _hasMoreActions =>
      widget.canRejoin ||
      (widget.canLeave && !widget.hasLeft) ||
      (widget.kind == 'group' && !widget.hasLeft);

  List<Widget> _tabBodies(BuildContext context) {
    final handle = NestedScrollView.sliverOverlapAbsorberHandleFor(context);
    return [
      if (_showParticipants) _participantsTab(handle),
      _galleryTab(handle),
      _linksTab(handle),
      _filesTab(handle),
    ];
  }

  Widget _galleryTab(SliverOverlapAbsorberHandle handle) {
    if (_media.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverOverlapInjector(handle: handle),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Нет изображений')),
          ),
        ],
      );
    }
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(handle: handle),
        SliverPadding(
          padding: const EdgeInsets.all(8),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final item = _media[i];
                return GestureDetector(
                  onTap: () => _openGalleryItem(item),
                  onLongPress: () {
                    final messageId = _messageIdOf(item);
                    if (messageId != null) {
                      _showItemActions(
                        title: 'Открыть фото',
                        onOpen: () => _openGalleryItem(item),
                        messageId: messageId,
                      );
                    }
                  },
                  child: ChatNetworkImage(
                    threadId: widget.threadId,
                    attachment: item,
                    fit: BoxFit.cover,
                  ),
                );
              },
              childCount: _media.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _linksTab(SliverOverlapAbsorberHandle handle) {
    if (_links.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverOverlapInjector(handle: handle),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Нет ссылок')),
          ),
        ],
      );
    }
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(handle: handle),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final item = _links[i];
              final url = item['url']?.toString() ?? '';
              final messageId = _messageIdOf(item);
              return ListTile(
                title: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _showItemActions(
                  title: 'Открыть ссылку',
                  onOpen: () => launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  ),
                  messageId: messageId,
                ),
              );
            },
            childCount: _links.length,
          ),
        ),
      ],
    );
  }

  Widget _filesTab(SliverOverlapAbsorberHandle handle) {
    if (_files.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverOverlapInjector(handle: handle),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Нет файлов')),
          ),
        ],
      );
    }
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(handle: handle),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final f = _files[i];
              final url = f['file_url']?.toString();
              final messageId = _messageIdOf(f);
              return ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(f['filename']?.toString() ?? 'Файл'),
                onTap: () => _showItemActions(
                  title: 'Открыть файл',
                  onOpen: url != null
                      ? () => launchUrl(
                            Uri.parse(url),
                            mode: LaunchMode.externalApplication,
                          )
                      : null,
                  messageId: messageId,
                ),
              );
            },
            childCount: _files.length,
          ),
        ),
      ],
    );
  }

  Future<void> _showMuteOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                title: const Text('1 час'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('1h');
                }),
            ListTile(
                title: const Text('4 часа'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('4h');
                }),
            ListTile(
                title: const Text('8 часов'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('8h');
                }),
            ListTile(
                title: const Text('24 часа'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('24h');
                }),
            ListTile(
                title: const Text('Навсегда'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('forever');
                }),
            ListTile(
                title: const Text('Включить уведомления'),
                onTap: () {
                  Navigator.pop(ctx);
                  _mute('off');
                }),
          ],
        ),
      ),
    );
  }

  int? _messageIdOf(Map<String, dynamic> item) {
    final id = item['message_id'];
    if (id is int) return id;
    return int.tryParse(id?.toString() ?? '');
  }

  Future<void> _goToMessage(int messageId) async {
    Navigator.of(context).pop();
    await widget.onGoToMessage?.call(messageId);
  }

  Future<void> _showItemActions({
    required String title,
    required VoidCallback? onOpen,
    int? messageId,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onOpen != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text(title),
                onTap: () => Navigator.pop(ctx, 'open'),
              ),
            if (messageId != null && widget.onGoToMessage != null)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Перейти к сообщению'),
                onTap: () => Navigator.pop(ctx, 'goto'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'open') onOpen?.call();
    if (action == 'goto' && messageId != null) {
      await _goToMessage(messageId);
    }
  }

  void _openGalleryItem(Map<String, dynamic> item) {
    final repo = ref.read(familychatRepositoryProvider);
    final url = chatAttachmentImageUrl(
      repo: repo,
      threadId: widget.threadId,
      attachment: item,
    );
    final messageId = _messageIdOf(item);
    final openImage = widget.onOpenImage;
    if (openImage == null) return;

    Navigator.of(context).pop();
    openImage(
      imageUrl: url,
      filename: item['filename']?.toString(),
      messageId: messageId,
      attachment: item,
    );
  }

  Widget _buildNameRow(BuildContext context, {required bool onDark}) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
      color: onDark ? Colors.white : theme.colorScheme.onSurface,
    );
    final subtitleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: onDark
          ? Colors.white.withValues(alpha: 0.85)
          : theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                _title,
                style: titleStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                Icons.edit_outlined,
                size: 18,
                color: onDark
                    ? Colors.white.withValues(alpha: 0.9)
                    : theme.colorScheme.primary,
              ),
              tooltip: 'Переименовать',
              onPressed: _renameChat,
            ),
          ],
        ),
        if (_headerSubtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _headerSubtitle!,
              style: subtitleStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        if (_customTitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              widget.defaultTitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: onDark
                    ? Colors.white.withValues(alpha: 0.75)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  Widget _flexibleHeader(BuildContext context) {
    final theme = Theme.of(context);
    final hasPhoto =
        _headerAvatarUrl != null && _headerAvatarUrl!.trim().isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final settings =
            context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
        final maxExtent = settings?.maxExtent ?? _expandedHeaderHeight;
        final minExtent = settings?.minExtent ?? kToolbarHeight;
        final current = settings?.currentExtent ?? maxExtent;
        final range = (maxExtent - minExtent).clamp(1.0, double.infinity);
        final t = ((maxExtent - current) / range).clamp(0.0, 1.0);

        const expandedAvatarSize = 120.0;
        const collapsedAvatarSize = 44.0;
        final avatarSize =
            expandedAvatarSize + (collapsedAvatarSize - expandedAvatarSize) * t;
        final photoOpacity = (1 - t * 1.35).clamp(0.0, 1.0);
        final onDark = hasPhoto && photoOpacity > 0.25 && t < 0.55;
        final expandedTop = maxExtent * 0.22;
        const collapsedTop = 28.0;
        final avatarTop = expandedTop + (collapsedTop - expandedTop) * t;

        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            if (hasPhoto)
              Opacity(
                opacity: photoOpacity,
                child: FamilyPublicImage(
                  url: _headerAvatarUrl!,
                  fit: BoxFit.cover,
                  error: ColoredBox(
                    color: theme.colorScheme.surfaceContainerLow,
                  ),
                ),
              )
            else
              ColoredBox(color: theme.colorScheme.surfaceContainerLow),
            if (hasPhoto && photoOpacity > 0.05)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.08 * (1 - t)),
                      Colors.black.withValues(alpha: 0.5 * (1 - t * 0.85)),
                    ],
                  ),
                ),
              ),
            Positioned(
              top: avatarTop,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChatAvatar(
                    name: _title,
                    avatarUrl: _headerAvatarUrl,
                    radius: avatarSize / 2,
                  ),
                  SizedBox(height: 10 * (1 - t * 0.6)),
                  Opacity(
                    opacity: (1 - t * 0.15).clamp(0.0, 1.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildNameRow(context, onDark: onDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _actionButtonsRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _TgProfileAction(
            icon: Icons.chat_bubble_outline,
            label: 'Чат',
            onTap: () => Navigator.of(context).pop(),
          ),
          _TgProfileAction(
            icon: _notificationsEnabled
                ? Icons.notifications_outlined
                : Icons.notifications_off_outlined,
            label: 'Звук',
            onTap: _notificationsEnabled ? _showMuteOptions : () => _mute('off'),
          ),
          if (_isDm)
            _TgProfileAction(
              icon: Icons.call_outlined,
              label: 'Звонок',
              onTap: _startCall,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.55,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Material(
              color: theme.colorScheme.surface,
              child: Stack(
                children: [
                  NestedScrollView(
                    controller: scrollController,
                    headerSliverBuilder: (context, innerBoxIsScrolled) {
                      final handle =
                          NestedScrollView.sliverOverlapAbsorberHandleFor(
                        context,
                      );
                      return [
                        SliverOverlapAbsorber(
                          handle: handle,
                          sliver: SliverAppBar(
                            automaticallyImplyLeading: false,
                            expandedHeight: _expandedHeaderHeight,
                            pinned: true,
                            stretch: true,
                            elevation: innerBoxIsScrolled ? 0.5 : 0,
                            scrolledUnderElevation: 0.5,
                            backgroundColor: theme.colorScheme.surface,
                            surfaceTintColor: Colors.transparent,
                            actions: [
                              if (_hasMoreActions)
                                IconButton(
                                  icon: const Icon(Icons.more_vert),
                                  onPressed: _showMoreMenu,
                                ),
                            ],
                            flexibleSpace: FlexibleSpaceBar(
                              collapseMode: CollapseMode.parallax,
                              background: _flexibleHeader(context),
                            ),
                            bottom: PreferredSize(
                              preferredSize: const Size.fromHeight(116),
                              child: Column(
                                children: [
                                  _actionButtonsRow(context),
                                  TabBar(
                                    controller: _tabs,
                                    isScrollable: _showParticipants,
                                    tabs: [
                                      if (_showParticipants)
                                        const Tab(text: 'Участники'),
                                      const Tab(text: 'Галерея'),
                                      const Tab(text: 'Ссылки'),
                                      const Tab(text: 'Файлы'),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ];
                    },
                    body: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : Builder(
                            builder: (nestedContext) => TabBarView(
                              controller: _tabs,
                              children: _tabBodies(nestedContext),
                            ),
                          ),
                  ),
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade400,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _participantsTab(SliverOverlapAbsorberHandle handle) {
    if (_participants.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverOverlapInjector(handle: handle),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Нет участников')),
          ),
        ],
      );
    }
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(handle: handle),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              if (index.isOdd) {
                return Divider(
                  height: 1,
                  indent: 72,
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.4),
                );
              }
              final participant = _participants[index ~/ 2];
              final name =
                  participant['display_name']?.toString() ?? 'Участник';
              final uid = participant['user_id'];
              final userId = uid is int ? uid : int.tryParse('$uid');
              if (userId == null) return const SizedBox.shrink();
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                leading: ChatAvatar(
                  name: name,
                  avatarUrl: participant['avatar_url']?.toString(),
                  radius: 24,
                ),
                title: Text(name),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => _openParticipantProfile(userId),
              );
            },
            childCount: _participants.length * 2 - 1,
          ),
        ),
      ],
    );
  }
}

class _AddMembersDialog extends StatefulWidget {
  const _AddMembersDialog({
    required this.members,
    this.myUserId,
  });

  final List<Map<String, dynamic>> members;
  final int? myUserId;

  @override
  State<_AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends State<_AddMembersDialog> {
  final _selected = <int>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Добавить участников'),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.members.isEmpty
            ? const Text('Нет доступных участников семьи')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.members.length,
                itemBuilder: (context, index) {
                  final member = widget.members[index];
                  final uid = member['user_id'];
                  final userId = uid is int ? uid : int.tryParse('$uid');
                  if (userId == null) return const SizedBox.shrink();
                  final name = member['display_name']?.toString() ?? 'Участник';
                  return CheckboxListTile(
                    value: _selected.contains(userId),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selected.add(userId);
                        } else {
                          _selected.remove(userId);
                        }
                      });
                    },
                    secondary: ChatAvatar(
                      name: name,
                      avatarUrl: member['avatar_url']?.toString(),
                      radius: 20,
                    ),
                    title: Text(name),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена')),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected),
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}

class _RenameChatDialog extends StatefulWidget {
  const _RenameChatDialog({
    required this.initialTitle,
    required this.defaultTitle,
    required this.canReset,
  });

  final String initialTitle;
  final String defaultTitle;
  final bool canReset;

  @override
  State<_RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<_RenameChatDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Название чата'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 300,
        decoration: InputDecoration(
          hintText: widget.defaultTitle,
          helperText: 'Видно только вам',
        ),
      ),
      actions: [
        if (widget.canReset)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Сбросить'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _TgProfileAction extends StatelessWidget {
  const _TgProfileAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                size: 24,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
