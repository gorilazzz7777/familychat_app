import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/family_tab_bar.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../tdlib_local_file.dart';
import '../telegram_link_navigation.dart';
import '../telegram_tdlib_providers.dart';
import '../telegram_tdlib_service.dart';

/// Шторка профиля TG — layout как у [ChatInfoSheet] (DM).
class TelegramUserInfoSheet extends ConsumerStatefulWidget {
  const TelegramUserInfoSheet({
    super.key,
    required this.chatId,
    required this.profile,
    this.onLinkToFamily,
  });

  final int chatId;
  final TdlibUserProfile profile;
  final VoidCallback? onLinkToFamily;

  static Future<void> show(
    BuildContext context, {
    required int chatId,
    required TdlibUserProfile profile,
    VoidCallback? onLinkToFamily,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TelegramUserInfoSheet(
        chatId: chatId,
        profile: profile,
        onLinkToFamily: onLinkToFamily,
      ),
    );
  }

  @override
  ConsumerState<TelegramUserInfoSheet> createState() =>
      _TelegramUserInfoSheetState();
}

class _TelegramUserInfoSheetState extends ConsumerState<TelegramUserInfoSheet>
    with SingleTickerProviderStateMixin {
  static const _expandedPhotoHeight = 288.0;

  late final TabController _tabs;
  late TdlibUserProfile _profile;
  bool _muted = false;
  bool _loadingMedia = true;
  List<TdlibMessage> _media = const [];
  List<({int messageId, String url})> _links = const [];

  bool get _hasExpandedPhoto {
    return tdlibLocalFileExists(_profile.avatarLocalPath);
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

  @override
  Widget build(BuildContext context) {
    ref.watch(telegramTdlibServiceProvider);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final username = _profile.username.trim();
    final phone = _profile.phoneNumber.trim();
    final bio = _profile.bio.trim();

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
                                        name: _profile.displayName,
                                        localFilePath: _profile.avatarLocalPath,
                                        radius: 44,
                                      ),
                                      const SizedBox(height: 10),
                                    ],
                                    Text(
                                      _profile.displayName,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 26,
                                        height: 1.15,
                                      ),
                                    ),
                                    if (_profile.statusText.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          _profile.statusText,
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
                                padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _ActionChip(
                                      icon: LucideIcons.message_circle,
                                      tooltip: 'Чат',
                                      onTap: () => Navigator.of(context).pop(),
                                    ),
                                    const SizedBox(width: 10),
                                    _ActionChip(
                                      icon: _muted
                                          ? LucideIcons.bell_off
                                          : LucideIcons.bell,
                                      tooltip: 'Звук',
                                      onTap: _toggleMute,
                                    ),
                                    if (widget.onLinkToFamily != null) ...[
                                      const SizedBox(width: 10),
                                      _ActionChip(
                                        icon: LucideIcons.link,
                                        tooltip: 'Связать с семьёй',
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          widget.onLinkToFamily!();
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (username.isNotEmpty ||
                                  phone.isNotEmpty ||
                                  bio.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                  child: Column(
                                    children: [
                                      if (phone.isNotEmpty)
                                        ListTile(
                                          leading: Icon(
                                            LucideIcons.phone,
                                            color: theme.colorScheme.primary,
                                          ),
                                          title: Text(
                                            phone.startsWith('+')
                                                ? phone
                                                : '+$phone',
                                          ),
                                          subtitle: const Text('Мобильный'),
                                        ),
                                      if (username.isNotEmpty)
                                        ListTile(
                                          leading: Icon(
                                            LucideIcons.at_sign,
                                            color: theme.colorScheme.primary,
                                          ),
                                          title: Text('@$username'),
                                          subtitle:
                                              const Text('Имя пользователя'),
                                        ),
                                      if (bio.isNotEmpty)
                                        ListTile(
                                          leading: Icon(
                                            LucideIcons.info,
                                            color: theme.colorScheme.primary,
                                          ),
                                          title: Text(bio),
                                          subtitle: const Text('О себе'),
                                        ),
                                    ],
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
                                Tab(text: 'Галерея'),
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
                    tdlibLocalFileImage(path, fit: BoxFit.cover),
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

class _ActionChip extends StatelessWidget {
  const _ActionChip({
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
              child: Icon(icon, size: 22, color: theme.colorScheme.primary),
            ),
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
