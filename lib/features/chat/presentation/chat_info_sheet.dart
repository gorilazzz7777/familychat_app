import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/presence/user_presence.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'chat_call_screen.dart';
import 'widgets/chat_image_viewer.dart';
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

const _birthdayChatAvatarAsset = 'assets/chat/birthday_celebration_avatar.jpg';

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
    this.isBirthdayCelebration = false,
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
  final bool isBirthdayCelebration;
  final ChatTitleChanged? onTitleChanged;
  final VoidCallback? onMembershipChanged;
  final ChatGoToMessage? onGoToMessage;
  final ChatOpenImage? onOpenImage;

  @override
  ConsumerState<ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends ConsumerState<ChatInfoSheet>
    with SingleTickerProviderStateMixin {
  static const _expandedPhotoHeight = 288.0;

  late final TabController _tabs;
  late String _title;
  late String _customTitle;
  List<Map<String, dynamic>> _media = [];
  List<Map<String, dynamic>> _links = [];
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true;
  String? _headerAvatarUrl;
  String? _headerSubtitle;
  bool _notificationsEnabled = true;

  bool get _showParticipants =>
      (widget.kind == 'group' || widget.kind == 'family') && !widget.hasLeft;

  bool get _isDm => widget.kind == 'dm' && widget.peerUserId != null;

  bool get _hasHeaderNetworkPhoto {
    final url = _headerAvatarUrl?.trim();
    return url != null && url.isNotEmpty;
  }

  bool get _hasHeaderAssetPhoto => widget.isBirthdayCelebration;

  bool get _hasExpandedHeaderPhoto =>
      _hasHeaderNetworkPhoto || _hasHeaderAssetPhoto;

  String? get _headerAvatarAsset =>
      _hasHeaderAssetPhoto ? _birthdayChatAvatarAsset : null;

  int get _tabCount => _showParticipants ? 3 : 2;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _customTitle = widget.customTitle;
    _tabs = TabController(length: _tabCount, vsync: this);
    _tabs.addListener(_onTabChanged);
    _load();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(familychatRepositoryProvider);
    try {
      final futures = <Future<dynamic>>[
        repo.threadMedia(widget.threadId),
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
        _links = (links as List).cast<Map<String, dynamic>>();
        _notificationsEnabled = notif['notifications_enabled'] == true;
        if (_showParticipants) {
          _participants = participants;
        }
        if (peerProfile != null) {
          _headerAvatarUrl = peerProfile['avatar_url']?.toString();
          _headerSubtitle = userPresenceFromProfile(peerProfile).label;
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

  List<Widget> _tabContentSlivers() {
    final index = _tabs.index;
    if (_showParticipants) {
      return switch (index) {
        0 => _participantsSlivers(),
        1 => _gallerySlivers(),
        2 => _linksSlivers(),
        _ => const [SliverToBoxAdapter(child: SizedBox.shrink())],
      };
    }
    return switch (index) {
      0 => _gallerySlivers(),
      1 => _linksSlivers(),
      _ => const [SliverToBoxAdapter(child: SizedBox.shrink())],
    };
  }

  List<Widget> _gallerySlivers() {
    if (_media.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Нет изображений')),
        ),
      ];
    }
    return [
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
    ];
  }

  List<Widget> _linksSlivers() {
    if (_links.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Нет ссылок')),
        ),
      ];
    }
    return [
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
    ];
  }

  List<Widget> _participantsSlivers() {
    if (_participants.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Нет участников')),
        ),
      ];
    }
    return [
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
            final name = participant['display_name']?.toString() ?? 'Участник';
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
    ];
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

  Future<void> _openProfilePhoto() async {
    if (!mounted) return;
    if (_hasHeaderNetworkPhoto) {
      await ChatImageViewer.open(
        context,
        imageUrl: _headerAvatarUrl!.trim(),
        filename: _title.isNotEmpty ? '$_title.jpg' : 'avatar.jpg',
      );
      return;
    }
    if (!_hasHeaderAssetPhoto) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image.asset(
                _birthdayChatAvatarAsset,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _profileDisplayName {
    final custom = _customTitle.trim();
    final defaultName = widget.defaultTitle.trim();
    if (custom.isNotEmpty &&
        defaultName.isNotEmpty &&
        custom != defaultName) {
      return '${_title.trim()} ($defaultName)';
    }
    return _title;
  }

  Widget _profileInfoSection(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        _hasExpandedHeaderPhoto ? 12 : 8,
        16,
        2,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (!_hasExpandedHeaderPhoto) ...[
                  ChatAvatar(
                    name: _title,
                    avatarUrl: _headerAvatarUrl,
                    assetPath: _headerAvatarAsset,
                    radius: 44,
                  ),
                  const SizedBox(height: 10),
                ],
                _buildNameRow(context),
              ],
            ),
          ),
          if (_hasMoreActions && !_hasExpandedHeaderPhoto)
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: _showMoreMenu,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNameRow(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      fontSize: 26,
      height: 1.15,
    );
    final statusStyle = theme.textTheme.titleSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                _profileDisplayName,
                style: titleStyle,
                maxLines: 2,
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
                size: 20,
                color: theme.colorScheme.primary,
              ),
              tooltip: 'Переименовать',
              onPressed: _renameChat,
            ),
          ],
        ),
        if (_headerSubtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _headerSubtitle!,
              style: statusStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  Widget _flexiblePhotoHeader(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final settings =
            context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
        final maxExtent = settings?.maxExtent ?? _expandedPhotoHeight;
        final minExtent = settings?.minExtent ?? kToolbarHeight;
        final current = settings?.currentExtent ?? maxExtent;
        final range = (maxExtent - minExtent).clamp(1.0, double.infinity);
        final t = ((maxExtent - current) / range).clamp(0.0, 1.0);

        const collapsedAvatarSize = 44.0;
        final showCollapsedAvatar = t > 0.62;
        final avatarOpacity = showCollapsedAvatar
            ? ((t - 0.62) / 0.38).clamp(0.0, 1.0)
            : 0.0;

        return ColoredBox(
          color: theme.colorScheme.surface,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              if (_hasHeaderNetworkPhoto)
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _openProfilePhoto,
                      child: Opacity(
                        opacity: (1 - t * 0.9).clamp(0.0, 1.0),
                        child: FamilyPublicImage(
                          url: _headerAvatarUrl!,
                          fit: BoxFit.cover,
                          error: ColoredBox(
                            color: theme.colorScheme.surfaceContainerLow,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else if (_hasHeaderAssetPhoto)
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _openProfilePhoto,
                      child: Opacity(
                        opacity: (1 - t * 0.9).clamp(0.0, 1.0),
                        child: Image.asset(
                          _birthdayChatAvatarAsset,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              if (showCollapsedAvatar && avatarOpacity > 0.12)
                Opacity(
                  opacity: avatarOpacity,
                  child: Center(
                    child: Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _openProfilePhoto,
                        customBorder: const CircleBorder(),
                        child: ChatAvatar(
                          name: _title,
                          avatarUrl: _headerAvatarUrl,
                          assetPath: _headerAvatarAsset,
                          radius: collapsedAvatarSize / 2,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_hasMoreActions)
                Positioned(
                  top: 2,
                  right: 0,
                  child: IconButton(
                    icon: Icon(
                      Icons.more_vert,
                      color: _hasExpandedHeaderPhoto && t < 0.45
                          ? Colors.white
                          : theme.colorScheme.onSurface,
                    ),
                    onPressed: _showMoreMenu,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _pinnedTabBar(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      child: TabBar(
        controller: _tabs,
        isScrollable: _showParticipants,
        tabs: [
          if (_showParticipants) const Tab(text: 'Участники'),
          const Tab(text: 'Галерея'),
          const Tab(text: 'Ссылки'),
        ],
      ),
    );
  }

  Widget _actionButtonsRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _TgProfileAction(
            icon: Icons.chat_bubble_outline,
            tooltip: 'Чат',
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 10),
          _TgProfileAction(
            icon: _notificationsEnabled
                ? Icons.notifications_outlined
                : Icons.notifications_off_outlined,
            tooltip: 'Звук',
            onTap: _notificationsEnabled ? _showMuteOptions : () => _mute('off'),
          ),
          if (_isDm) ...[
            const SizedBox(width: 10),
            _TgProfileAction(
              icon: Icons.call_outlined,
              tooltip: 'Звонок',
              onTap: _startCall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _profileDetailsSection(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _profileInfoSection(context),
          _actionButtonsRow(context),
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
        minChildSize: 0.15,
        maxChildSize: 0.95,
        expand: false,
        shouldCloseOnMinExtent: true,
        builder: (context, scrollController) {
          return ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Material(
              color: theme.colorScheme.surface,
              child: Stack(
                children: [
                  CustomScrollView(
                    controller: scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (_hasExpandedHeaderPhoto)
                        SliverAppBar(
                          automaticallyImplyLeading: false,
                          expandedHeight: _expandedPhotoHeight,
                          collapsedHeight: 72,
                          toolbarHeight: 0,
                          pinned: true,
                          stretch: false,
                          elevation: 0,
                          scrolledUnderElevation: 0,
                          shadowColor: Colors.transparent,
                          backgroundColor: theme.colorScheme.surface,
                          surfaceTintColor: Colors.transparent,
                          flexibleSpace: FlexibleSpaceBar(
                            collapseMode: CollapseMode.pin,
                            background: _flexiblePhotoHeader(context),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: _profileDetailsSection(context),
                      ),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _ChatInfoTabBarDelegate(
                          child: _pinnedTabBar(context),
                        ),
                      ),
                      if (_loading)
                        const SliverFillRemaining(
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else
                        ..._tabContentSlivers(),
                    ],
                  ),
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
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
                  ),
                ],
              ),
            ),
          );
        },
      ),
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
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
            if (widget.canReset)
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: () => Navigator.pop(context, ''),
                child: const Text('Сбросить'),
              ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => Navigator.pop(context, _controller.text.trim()),
              child: const Text('Сохранить'),
            ),
          ],
          ),
        ),
      ],
    );
  }
}

class _ChatInfoTabBarDelegate extends SliverPersistentHeaderDelegate {
  _ChatInfoTabBarDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _ChatInfoTabBarDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}

class _TgProfileAction extends StatelessWidget {
  const _TgProfileAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Icon(
                icon,
                size: 22,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
