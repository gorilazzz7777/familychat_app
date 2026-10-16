import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/widgets/family_tab_bar.dart';
import '../../chat/presentation/widgets/chat_link_item_actions.dart';
import '../../chat/presentation/widgets/chat_link_preview_tile.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../tdlib_local_file.dart';
import '../telegram_link_navigation.dart';
import '../telegram_match_store.dart';
import '../telegram_tdlib_providers.dart';
import '../telegram_tdlib_service.dart';
import 'telegram_sheet_media_thumb.dart';
import 'telegram_user_info_sheet.dart';

/// Шторка профиля канала/группы TG — как в официальном клиенте
/// (аватар, подписчики, Звук/Ссылка/Покинуть, описание, Медиа/Ссылки).
class TelegramChatInfoSheet extends ConsumerStatefulWidget {
  const TelegramChatInfoSheet({
    super.key,
    required this.chatId,
    required this.profile,
    this.onGoToMessage,
  });

  final int chatId;
  final TdlibChatProfile profile;
  final Future<void> Function(int messageId)? onGoToMessage;

  static Future<void> show(
    BuildContext context, {
    required int chatId,
    required TdlibChatProfile profile,
    Future<void> Function(int messageId)? onGoToMessage,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TelegramChatInfoSheet(
        chatId: chatId,
        profile: profile,
        onGoToMessage: onGoToMessage,
      ),
    );
  }

  @override
  ConsumerState<TelegramChatInfoSheet> createState() =>
      _TelegramChatInfoSheetState();
}

class _TelegramChatInfoSheetState extends ConsumerState<TelegramChatInfoSheet>
    with SingleTickerProviderStateMixin {
  static const _expandedPhotoHeight = 288.0;

  late final TabController _tabs;
  late TdlibChatProfile _profile;
  bool _muted = false;
  bool _loadingMedia = true;
  bool _loadingMembers = true;
  List<TdlibMessage> _media = const [];
  List<({int messageId, String url})> _links = const [];
  List<TdlibChatMember> _members = const [];
  bool _amCreator = false;

  bool get _showMembers => !_profile.isChannel;

  int get _tabCount => _showMembers ? 3 : 2;

  bool get _hasExpandedPhoto {
    return tdlibLocalFileExists(_profile.avatarLocalPath);
  }

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
    _tabs = TabController(length: _tabCount, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && mounted) setState(() {});
    });
    final svc = ref.read(telegramTdlibServiceProvider);
    _muted = svc.isChatMuted(widget.chatId);
    svc.addListener(_onTdlibChanged);
    unawaited(_loadTabs());
  }

  @override
  void dispose() {
    ref.read(telegramTdlibServiceProvider).removeListener(_onTdlibChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTdlibChanged() {
    if (!mounted || !_showMembers || _members.isEmpty) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    var changed = false;
    final next = <TdlibChatMember>[];
    for (final m in _members) {
      final path = svc.userAvatarLocalPath(m.userId);
      if (path != null && path.isNotEmpty && path != m.avatarLocalPath) {
        changed = true;
        next.add(
          TdlibChatMember(
            userId: m.userId,
            displayName: m.displayName,
            avatarLocalPath: path,
            avatarMinithumbnailBytes: m.avatarMinithumbnailBytes,
            isCreator: m.isCreator,
            isAdmin: m.isAdmin,
          ),
        );
      } else {
        next.add(m);
      }
    }
    if (changed) setState(() => _members = next);
  }

  Future<void> _openMemberProfile(TdlibChatMember member) async {
    final match = await TelegramMatchStore.instance.get(member.userId);
    final fcId = match?.fcUserId ?? 0;
    if (fcId > 0) {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MemberProfileScreen(userId: fcId),
        ),
      );
      return;
    }
    final svc = ref.read(telegramTdlibServiceProvider);
    final profile = await svc.loadUserProfile(member.userId);
    if (!mounted || profile == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть профиль')),
        );
      }
      return;
    }
    final dmChatId =
        svc.privateChatIdForUser(member.userId) ?? widget.chatId;
    await TelegramUserInfoSheet.show(
      context,
      chatId: dmChatId,
      profile: profile,
    );
  }

  Future<void> _loadTabs() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    final mediaFut = svc.searchChatMedia(widget.chatId);
    final linksFut = svc.searchChatLinks(widget.chatId);
    final membersFut =
        _showMembers ? svc.chatMembers(widget.chatId) : Future.value(const <TdlibChatMember>[]);
    final creatorFut =
        _showMembers ? svc.amChatCreator(widget.chatId) : Future.value(false);
    final media = await mediaFut;
    final links = await linksFut;
    final members = await membersFut;
    final amCreator = await creatorFut;
    if (!mounted) return;
    setState(() {
      _media = media;
      _links = links;
      _members = members;
      _amCreator = amCreator;
      _loadingMedia = false;
      _loadingMembers = false;
    });
  }

  Future<void> _reloadMembers() async {
    if (!_showMembers) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final members = await svc.chatMembers(widget.chatId);
    final amCreator = await svc.amChatCreator(widget.chatId);
    if (!mounted) return;
    setState(() {
      _members = members;
      _amCreator = amCreator;
      _loadingMembers = false;
    });
  }

  Future<void> _confirmRemoveMember(TdlibChatMember member) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить участника'),
        content: Text(
          'Удалить ${member.displayName} из группы? Сообщения останутся в истории.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(telegramTdlibServiceProvider)
          .removeChatMember(widget.chatId, member.userId);
      if (!mounted) return;
      await _reloadMembers();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${member.displayName} удалён(а) из группы')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось удалить: $e')),
      );
    }
  }

  Future<void> _onMemberLongPress(TdlibChatMember member) async {
    final myId = ref.read(telegramTdlibServiceProvider).myUserId;
    final canRemove = _amCreator &&
        !member.isCreator &&
        member.userId != myId;
    if (!canRemove) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.user_minus),
              title: const Text('Удалить участника'),
              subtitle: Text(member.displayName),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_confirmRemoveMember(member));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    setState(() => _muted = next);
    try {
      await ref.read(telegramTdlibServiceProvider).setChatMuted(
            widget.chatId,
            muted: next,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(next ? 'Уведомления отключены' : 'Уведомления включены'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _muted = !next);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось изменить уведомления: $e')),
      );
    }
  }

  Future<void> _copyLink() async {
    final link = _profile.publicLink;
    if (link.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ссылка недоступна')),
      );
      return;
    }
    final full = link.startsWith('http') ? link : 'https://$link';
    await Clipboard.setData(ClipboardData(text: full));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Скопировано: $link')),
    );
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_profile.isChannel ? 'Покинуть канал?' : 'Покинуть группу?'),
        content: Text(_profile.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Покинуть'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(telegramTdlibServiceProvider).leaveChat(widget.chatId);
      if (!mounted) return;
      Navigator.of(context).pop(); // sheet
      Navigator.of(context).maybePop(); // conversation
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось покинуть: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when TDLib finishes downloading sheet thumbs.
    ref.watch(telegramTdlibServiceProvider);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final description = _profile.description.trim();
    final publicLink = _profile.publicLink;
    final username = _profile.username.trim();

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.35,
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
                      if (_hasExpandedPhoto)
                        SliverAppBar(
                          automaticallyImplyLeading: false,
                          expandedHeight: _expandedPhotoHeight,
                          collapsedHeight: 72,
                          toolbarHeight: 0,
                          pinned: true,
                          elevation: 0,
                          backgroundColor: theme.colorScheme.surface,
                          flexibleSpace: FlexibleSpaceBar(
                            collapseMode: CollapseMode.pin,
                            background: tdlibLocalFileImage(
                              _profile.avatarLocalPath!,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: ColoredBox(
                          color: theme.colorScheme.surface,
                          child: Column(
                            children: [
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  _hasExpandedPhoto ? 12 : 20,
                                  16,
                                  2,
                                ),
                                child: Column(
                                  children: [
                                    if (!_hasExpandedPhoto) ...[
                                      ChatAvatar(
                                        name: _profile.title,
                                        localFilePath:
                                            _profile.avatarLocalPath,
                                        memoryBytes: _profile
                                            .avatarMinithumbnailBytes,
                                        radius: 44,
                                      ),
                                      const SizedBox(height: 10),
                                    ],
                                    Text(
                                      _profile.title,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 26,
                                        height: 1.15,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        _profile.memberCount > 0
                                            ? _profile.memberCountLabel
                                            : _profile.kindLabel,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 10, 16, 10),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _LabeledAction(
                                        icon: _muted
                                            ? LucideIcons.bell_off
                                            : LucideIcons.bell,
                                        label: 'Звук',
                                        onTap: _toggleMute,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _LabeledAction(
                                        icon: LucideIcons.link,
                                        label: 'Ссылка',
                                        onTap: _copyLink,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _LabeledAction(
                                        icon: LucideIcons.log_out,
                                        label: 'Покинуть',
                                        onTap: _leave,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (description.isNotEmpty ||
                                  publicLink.isNotEmpty ||
                                  username.isNotEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    elevation: 0,
                                    color: theme
                                        .colorScheme.surfaceContainerHighest
                                        .withValues(alpha: 0.55),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Column(
                                      children: [
                                        if (description.isNotEmpty)
                                          ListTile(
                                            title: Text(description),
                                            subtitle: const Text('Описание'),
                                          ),
                                        if (username.isNotEmpty)
                                          ListTile(
                                            leading: Icon(
                                              LucideIcons.at_sign,
                                              color: theme.colorScheme.primary,
                                            ),
                                            title: Text('@$username'),
                                            subtitle: const Text(
                                              'Имя пользователя',
                                            ),
                                            onTap: _copyLink,
                                          ),
                                        if (publicLink.isNotEmpty)
                                          ListTile(
                                            leading: Icon(
                                              LucideIcons.link,
                                              color: theme.colorScheme.primary,
                                            ),
                                            title: Text(publicLink),
                                            subtitle: const Text(
                                              'Ссылка-приглашение',
                                            ),
                                            trailing: IconButton(
                                              tooltip: 'Открыть',
                                              icon: const Icon(
                                                LucideIcons.external_link,
                                                size: 20,
                                              ),
                                              onPressed: () {
                                                final full =
                                                    publicLink.startsWith(
                                                  'http',
                                                )
                                                        ? publicLink
                                                        : 'https://$publicLink';
                                                unawaited(
                                                  launchUrl(
                                                    Uri.parse(full),
                                                    mode: LaunchMode
                                                        .externalApplication,
                                                  ),
                                                );
                                              },
                                            ),
                                            onTap: _copyLink,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _TabBarDelegate(
                          child: Material(
                            color: theme.colorScheme.surface,
                            child: FamilyTabBar.build(
                              controller: _tabs,
                              tabs: [
                                if (_showMembers) const Tab(text: 'Участники'),
                                const Tab(text: 'Медиа'),
                                const Tab(text: 'Ссылки'),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_loadingMedia)
                        const SliverFillRemaining(
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else
                        ..._tabSlivers(),
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

  List<Widget> _tabSlivers() {
    final membersOffset = _showMembers ? 1 : 0;
    final mediaIndex = membersOffset;
    final linksIndex = membersOffset + 1;

    if (_showMembers && _tabs.index == 0) {
      return _membersSlivers();
    }
    if (_tabs.index == linksIndex) {
      if (_loadingMedia) {
        return const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
        ];
      }
      if (_links.isEmpty) {
        return const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Нет ссылок')),
          ),
        ];
      }
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final item = _links[i];
                final url = item.url;
                final messageId = item.messageId;
                final goTo = widget.onGoToMessage;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ChatLinkPreviewTile(
                    url: url,
                    onTap: () {
                      unawaited(
                        showChatLinkItemActions(
                          context,
                          onOpen: () => TelegramLinkNavigation.openOrLaunch(
                            url,
                            currentChatId: widget.chatId,
                          ),
                          onGoToMessage: messageId > 0 && goTo != null
                              ? () => goToChatInfoMessage(
                                    context,
                                    messageId: messageId,
                                    onGoToMessage: goTo,
                                  )
                              : null,
                        ),
                      );
                    },
                  ),
                );
              },
              childCount: _links.length,
            ),
          ),
        ),
      ];
    }
    if (_tabs.index != mediaIndex) {
      return const [SliverToBoxAdapter(child: SizedBox.shrink())];
    }
    if (_loadingMedia) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_media.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Нет медиа')),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.all(8),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => TelegramSheetMediaThumb(
              message: _media[i],
              gallery: _media,
              onGoToMessage: widget.onGoToMessage,
            ),
            childCount: _media.length,
          ),
        ),
      ),
    ];
  }

  List<Widget> _membersSlivers() {
    if (_loadingMembers) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_members.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Нет участников')),
        ),
      ];
    }
    final myId = ref.read(telegramTdlibServiceProvider).myUserId;
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
            final member = _members[index ~/ 2];
            final canRemove = _amCreator &&
                !member.isCreator &&
                member.userId != myId;
            final role = member.isCreator
                ? 'Создатель'
                : (member.isAdmin ? 'Админ' : null);
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: ChatAvatar(
                name: member.displayName,
                localFilePath: member.avatarLocalPath,
                memoryBytes: member.avatarMinithumbnailBytes,
                radius: 24,
              ),
              title: Text(member.displayName),
              subtitle: role == null ? null : Text(role),
              onTap: () => unawaited(_openMemberProfile(member)),
              onLongPress: canRemove
                  ? () => unawaited(_onMemberLongPress(member))
                  : null,
            );
          },
          childCount: _members.length * 2 - 1,
        ),
      ),
    ];
  }
}

class _LabeledAction extends StatelessWidget {
  const _LabeledAction({
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
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: theme.colorScheme.primary),
              const SizedBox(height: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) =>
      oldDelegate.child != child;
}
