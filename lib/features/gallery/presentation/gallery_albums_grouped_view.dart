import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/presentation/widgets/chat_network_image.dart';
import '../../profile/presentation/profile_gallery_album_screen.dart';

Future<void> openProfileGalleryAlbum(
  BuildContext context, {
  required int userId,
  required String albumId,
  required String title,
  bool canManage = false,
  bool isOwnGallery = false,
  bool isFamilyGallery = false,
  int? excludeUploadedByUserId,
  Future<void> Function()? onClosed,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ProfileGalleryAlbumScreen(
        userId: userId,
        albumId: albumId,
        title: title,
        canManage: canManage,
        isOwnGallery: isOwnGallery,
        isFamilyGallery: isFamilyGallery,
        excludeUploadedByUserId: excludeUploadedByUserId,
      ),
    ),
  );
  await onClosed?.call();
}

class GalleryAlbumsGroupedView extends StatefulWidget {
  const GalleryAlbumsGroupedView({
    super.key,
    required this.albums,
    required this.userId,
    required this.onRefresh,
    this.isOwnGallery = false,
    this.isFamilyGallery = false,
    this.faceHintMessage = '',
    this.showFaceHint = false,
    this.onAlbumLongPress,
    this.customTabLabel = 'Мои альбомы',
    this.excludeUploadedByUserId,
    this.alwaysShowCustomGroup = false,
  });

  final List<Map<String, dynamic>> albums;
  final int userId;
  final Future<void> Function() onRefresh;
  final bool isOwnGallery;
  final bool isFamilyGallery;
  final String faceHintMessage;
  final bool showFaceHint;
  final void Function(Map<String, dynamic> album)? onAlbumLongPress;
  final String customTabLabel;
  final int? excludeUploadedByUserId;
  final bool alwaysShowCustomGroup;

  @override
  State<GalleryAlbumsGroupedView> createState() =>
      _GalleryAlbumsGroupedViewState();
}

class _GalleryAlbumGroup {
  const _GalleryAlbumGroup({
    required this.id,
    required this.label,
    required this.icon,
    required this.albums,
  });

  final String id;
  final String label;
  final IconData icon;
  final List<Map<String, dynamic>> albums;
}

class _GalleryAlbumsGroupedViewState extends State<GalleryAlbumsGroupedView> {
  List<_GalleryAlbumGroup> _groups = [];
  Map<String, dynamic>? _allAlbum;
  int _selectedGroupIndex = 0;

  @override
  void initState() {
    super.initState();
    _applyGroups(_buildGroups());
  }

  @override
  void didUpdateWidget(covariant GalleryAlbumsGroupedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albums != widget.albums) {
      _rebuildGroups();
    }
  }

  ({
    List<_GalleryAlbumGroup> groups,
    Map<String, dynamic>? allAlbum,
    int selected
  }) _buildGroups() {
    final byKind = <String, List<Map<String, dynamic>>>{};
    Map<String, dynamic>? allAlbum;

    for (final album in widget.albums) {
      final kind = album['kind']?.toString() ?? '';
      if (kind == 'all') {
        allAlbum = album;
        continue;
      }
      byKind.putIfAbsent(kind, () => []).add(album);
    }

    final groups = <_GalleryAlbumGroup>[
      if (widget.alwaysShowCustomGroup || (byKind['custom'] ?? []).isNotEmpty)
        _GalleryAlbumGroup(
          id: 'custom',
          label: widget.customTabLabel,
          icon: Icons.collections_bookmark_outlined,
          albums: List<Map<String, dynamic>>.from(byKind['custom'] ?? const []),
        ),
      if ((byKind['face'] ?? []).isNotEmpty)
        _GalleryAlbumGroup(
          id: 'face',
          label: 'Люди',
          icon: Icons.face_outlined,
          albums: List<Map<String, dynamic>>.from(byKind['face']!),
        ),
      if ((byKind['place'] ?? []).isNotEmpty)
        _GalleryAlbumGroup(
          id: 'place',
          label: 'Места',
          icon: Icons.place_outlined,
          albums: List<Map<String, dynamic>>.from(byKind['place']!),
        ),
      if ((byKind['year'] ?? []).isNotEmpty)
        _GalleryAlbumGroup(
          id: 'year',
          label: 'Годы',
          icon: Icons.calendar_today_outlined,
          albums: List<Map<String, dynamic>>.from(byKind['year']!),
        ),
    ];

    var selected = _selectedGroupIndex;
    if (groups.isEmpty) {
      selected = 0;
    } else if (selected >= groups.length) {
      selected = 0;
    }

    return (groups: groups, allAlbum: allAlbum, selected: selected);
  }

  void _applyGroups(
      ({
        List<_GalleryAlbumGroup> groups,
        Map<String, dynamic>? allAlbum,
        int selected
      }) data) {
    _groups = data.groups;
    _allAlbum = data.allAlbum;
    _selectedGroupIndex = data.selected;
  }

  void _rebuildGroups() {
    _applyGroups(_buildGroups());
    if (mounted) setState(() {});
  }

  IconData _albumIcon(String? kind) {
    return switch (kind) {
      'year' => Icons.calendar_today_outlined,
      'place' => Icons.place_outlined,
      'face' => Icons.face_outlined,
      'custom' => Icons.collections_bookmark_outlined,
      _ => Icons.photo_library_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hasContent = _allAlbum != null || _groups.isNotEmpty;

    if (!hasContent) {
      return RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Center(child: Text('Пока нет фото в галерее')),
          ],
        ),
      );
    }

    final selectedGroup = _groups.isEmpty ? null : _groups[_selectedGroupIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showFaceHint && widget.faceHintMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Material(
              color: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.face_retouching_natural_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.faceHintMessage,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_allAlbum != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _AllPhotosCard(
              album: _allAlbum!,
              userId: widget.userId,
              isOwnGallery: widget.isOwnGallery,
              isFamilyGallery: widget.isFamilyGallery,
              excludeUploadedByUserId: widget.excludeUploadedByUserId,
              onClosed: widget.onRefresh,
            ),
          ),
        if (_groups.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _groups.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final group = _groups[index];
                final selected = index == _selectedGroupIndex;
                return FilterChip(
                  label: Text('${group.label} (${group.albums.length})'),
                  avatar: Icon(group.icon, size: 18),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (_) =>
                      setState(() => _selectedGroupIndex = index),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: selectedGroup == null
                ? const SizedBox.shrink()
                : RefreshIndicator(
                    onRefresh: widget.onRefresh,
                    child: _AlbumGrid(
                      albums: selectedGroup.albums,
                      userId: widget.userId,
                      isOwnGallery: widget.isOwnGallery,
                      isFamilyGallery: widget.isFamilyGallery,
                      excludeUploadedByUserId: widget.excludeUploadedByUserId,
                      iconForKind: _albumIcon,
                      onAlbumLongPress: widget.onAlbumLongPress,
                      onAlbumClosed: widget.onRefresh,
                      emptyLabel:
                          'В разделе «${selectedGroup.label}» пока нет альбомов',
                    ),
                  ),
          ),
        ] else
          Expanded(
            child: RefreshIndicator(
              onRefresh: widget.onRefresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 48),
                  Center(child: Text('Других альбомов пока нет')),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _AllPhotosCard extends ConsumerWidget {
  const _AllPhotosCard({
    required this.album,
    required this.userId,
    required this.isOwnGallery,
    required this.isFamilyGallery,
    this.excludeUploadedByUserId,
    this.onClosed,
  });

  final Map<String, dynamic> album;
  final int userId;
  final bool isOwnGallery;
  final bool isFamilyGallery;
  final int? excludeUploadedByUserId;
  final Future<void> Function()? onClosed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final title = album['title']?.toString() ?? 'Все фото';
    final count = album['count']?.toString() ?? '0';
    final cover = album['cover'] is Map<String, dynamic>
        ? album['cover'] as Map<String, dynamic>
        : null;
    final threadId = cover?['thread_id'];

    return Material(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await openProfileGalleryAlbum(
            context,
            userId: userId,
            albumId: 'all',
            title: title,
            isOwnGallery: isOwnGallery,
            isFamilyGallery: isFamilyGallery,
            excludeUploadedByUserId: excludeUploadedByUserId,
            onClosed: onClosed,
          );
        },
        child: SizedBox(
          height: 112,
          child: Row(
            children: [
              SizedBox(
                width: 112,
                height: 112,
                child: cover != null && threadId is int
                    ? ChatNetworkImage(
                        threadId: threadId,
                        attachment: cover,
                        fit: BoxFit.cover,
                      )
                    : ColoredBox(
                        color: theme.colorScheme.primaryContainer,
                        child: Icon(
                          Icons.photo_library_outlined,
                          size: 40,
                          color: theme.colorScheme.primary,
                        ),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$count фото',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({
    required this.albums,
    required this.userId,
    required this.isOwnGallery,
    required this.isFamilyGallery,
    this.excludeUploadedByUserId,
    required this.iconForKind,
    this.onAlbumLongPress,
    this.onAlbumClosed,
    required this.emptyLabel,
  });

  final List<Map<String, dynamic>> albums;
  final int userId;
  final bool isOwnGallery;
  final bool isFamilyGallery;
  final int? excludeUploadedByUserId;
  final IconData Function(String? kind) iconForKind;
  final void Function(Map<String, dynamic> album)? onAlbumLongPress;
  final Future<void> Function()? onAlbumClosed;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
          Center(child: Text(emptyLabel)),
        ],
      );
    }

    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.92,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        final canManage = album['can_manage'] == true;
        return _AlbumCard(
          album: album,
          icon: iconForKind(album['kind']?.toString()),
          userId: userId,
          isOwnGallery: isOwnGallery,
          isFamilyGallery: isFamilyGallery,
          excludeUploadedByUserId: excludeUploadedByUserId,
          onClosed: onAlbumClosed,
          onLongPress: canManage && onAlbumLongPress != null
              ? () => onAlbumLongPress!(album)
              : null,
        );
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.icon,
    required this.userId,
    required this.isOwnGallery,
    required this.isFamilyGallery,
    this.excludeUploadedByUserId,
    this.onClosed,
    this.onLongPress,
  });

  final Map<String, dynamic> album;
  final IconData icon;
  final int userId;
  final bool isOwnGallery;
  final bool isFamilyGallery;
  final int? excludeUploadedByUserId;
  final Future<void> Function()? onClosed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = album['title']?.toString() ?? '';
    final count = album['count']?.toString() ?? '0';
    final albumId = album['id']?.toString() ?? '';
    final canManage = album['can_manage'] == true;
    final cover = album['cover'] is Map<String, dynamic>
        ? album['cover'] as Map<String, dynamic>
        : null;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: albumId.isEmpty
            ? null
            : () async {
                await openProfileGalleryAlbum(
                  context,
                  userId: userId,
                  albumId: albumId,
                  title: title,
                  canManage: canManage,
                  isOwnGallery: isOwnGallery,
                  isFamilyGallery: isFamilyGallery,
                  excludeUploadedByUserId: excludeUploadedByUserId,
                  onClosed: onClosed,
                );
              },
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _AlbumCover(
                cover: cover,
                icon: icon,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '$count фото',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumCover extends StatelessWidget {
  const _AlbumCover({
    required this.cover,
    required this.icon,
  });

  final Map<String, dynamic>? cover;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final threadId = cover?['thread_id'];
    if (cover != null && threadId is int) {
      return ChatNetworkImage(
        threadId: threadId,
        attachment: cover!,
        fit: BoxFit.cover,
      );
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Center(
        child:
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
