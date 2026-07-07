import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import 'custom_album_dialog.dart';
import 'profile_gallery_album_screen.dart';

class ProfileGalleryTab extends ConsumerStatefulWidget {
  const ProfileGalleryTab({
    super.key,
    required this.userId,
    this.isOwnGallery = false,
  });

  final int userId;
  final bool isOwnGallery;

  @override
  ConsumerState<ProfileGalleryTab> createState() => _ProfileGalleryTabState();
}

class _ProfileGalleryTabState extends ConsumerState<ProfileGalleryTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _albums = [];
  String _faceHintMessage = '';
  bool _showFaceHint = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(familychatRepositoryProvider).memberGalleryAlbums(widget.userId);
      if (!mounted) return;
      setState(() {
        _albums = (data['albums'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _faceHintMessage = data['face_hint_message']?.toString() ?? '';
        _showFaceHint = data['show_face_hint'] == true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _createAlbum() async {
    final created = await CustomAlbumDialog.show(
      context,
      userId: widget.userId,
    );
    if (created == true) {
      await _load();
    }
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

  int? _customAlbumPk(Map<String, dynamic> album) {
    if (album['kind']?.toString() != 'custom') return null;
    final id = album['id']?.toString() ?? '';
    if (!id.startsWith('custom:')) return null;
    return int.tryParse(id.substring(7));
  }

  Future<void> _editAlbum(Map<String, dynamic> album) async {
    final pk = _customAlbumPk(album);
    if (pk == null) return;
    final accessIds = (album['access_user_ids'] as List<dynamic>? ?? [])
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
    final updated = await CustomAlbumDialog.show(
      context,
      userId: widget.userId,
      albumPk: pk,
      initialTitle: album['title']?.toString() ?? '',
      initialAccessMode: album['access_mode']?.toString() ?? 'all',
      initialAccessUserIds: accessIds,
    );
    if (updated == true) {
      await _load();
    }
  }

  Future<void> _deleteAlbum(Map<String, dynamic> album) async {
    final pk = _customAlbumPk(album);
    if (pk == null) return;
    final title = album['title']?.toString() ?? 'альбом';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить альбом?'),
        content: Text('Альбом «$title» будет удалён. Фото останутся в галерее.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(familychatRepositoryProvider).deleteCustomGalleryAlbum(widget.userId, pk);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  void _showAlbumMenu(Map<String, dynamic> album) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Редактировать'),
              onTap: () {
                Navigator.pop(ctx);
                _editAlbum(album);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text(
                'Удалить',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _deleteAlbum(album);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_showFaceHint && _faceHintMessage.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Material(
                    color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.45),
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
                              _faceHintMessage,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_albums.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('Пока нет фото в галерее')),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.92,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final album = _albums[index];
                      final canManage = album['can_manage'] == true;
                      return _AlbumCard(
                        album: album,
                        icon: _albumIcon(album['kind']?.toString()),
                        userId: widget.userId,
                        onLongPress: canManage ? () => _showAlbumMenu(album) : null,
                      );
                    },
                    childCount: _albums.length,
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: widget.isOwnGallery
          ? FloatingActionButton.extended(
              onPressed: _createAlbum,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Альбом'),
            )
          : null,
    );
  }
}

class _AlbumCard extends ConsumerWidget {
  const _AlbumCard({
    required this.album,
    required this.icon,
    required this.userId,
    this.onLongPress,
  });

  final Map<String, dynamic> album;
  final IconData icon;
  final int userId;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            : () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProfileGalleryAlbumScreen(
                      userId: userId,
                      albumId: albumId,
                      title: title,
                      canManage: canManage,
                    ),
                  ),
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
        child: Icon(icon, size: 40, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
