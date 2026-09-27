import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/widgets/family_tab_bar.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../telegram_link_navigation.dart';
import '../telegram_tdlib_providers.dart';
import '../telegram_tdlib_service.dart';

/// Шторка профиля канала/группы TG — как в официальном клиенте
/// (аватар, подписчики, Звук/Ссылка/Покинуть, описание, Медиа/Ссылки).
class TelegramChatInfoSheet extends ConsumerStatefulWidget {
  const TelegramChatInfoSheet({
    super.key,
    required this.chatId,
    required this.profile,
  });

  final int chatId;
  final TdlibChatProfile profile;

  static Future<void> show(
    BuildContext context, {
    required int chatId,
    required TdlibChatProfile profile,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TelegramChatInfoSheet(
        chatId: chatId,
        profile: profile,
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
  List<TdlibMessage> _media = const [];
  List<({int messageId, String url})> _links = const [];

  bool get _hasExpandedPhoto {
    final p = _profile.avatarLocalPath;
    return p != null && p.isNotEmpty && File(p).existsSync();
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && mounted) setState(() {});
    });
    _profile = widget.profile;
    _muted =
        ref.read(telegramTdlibServiceProvider).isChatMuted(widget.chatId);
    unawaited(_loadTabs());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadTabs() async {
    final svc = ref.read(telegramTdlibServiceProvider);
    final media = await svc.searchChatMedia(widget.chatId);
    final links = await svc.searchChatLinks(widget.chatId);
    if (!mounted) return;
    setState(() {
      _media = media;
      _links = links;
      _loadingMedia = false;
    });
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
                            background: Image.file(
                              File(_profile.avatarLocalPath!),
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
                              tabs: const [
                                Tab(text: 'Медиа'),
                                Tab(text: 'Ссылки'),
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
    if (_tabs.index == 1) {
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
                return ListTile(
                  leading: const Icon(LucideIcons.link),
                  title: Text(item.url, maxLines: 2),
                  onTap: () => unawaited(
                    TelegramLinkNavigation.openOrLaunch(item.url),
                  ),
                );
              },
              childCount: _links.length,
            ),
          ),
        ),
      ];
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
            (context, i) {
              final m = _media[i];
              final svc = ref.read(telegramTdlibServiceProvider);
              final path = m.photoLocalPath ??
                  (m.photoRemoteId != null
                      ? svc.cachedFilePath(m.photoRemoteId!)
                      : null) ??
                  m.videoThumbLocalPath ??
                  (m.videoThumbFileId != null
                      ? svc.cachedFilePath(m.videoThumbFileId!)
                      : null);
              if (path == null || path.isEmpty) {
                final fileId = m.photoRemoteId ?? m.videoThumbFileId;
                if (fileId != null) {
                  unawaited(svc.ensureFileLocal(fileId));
                }
                return ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Icon(
                      m.isVideo ? LucideIcons.video : LucideIcons.image,
                    ),
                  ),
                );
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(File(path), fit: BoxFit.cover),
                    if (m.isVideo)
                      const Align(
                        alignment: Alignment.center,
                        child: Icon(
                          LucideIcons.play,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                  ],
                ),
              );
            },
            childCount: _media.length,
          ),
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
