import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/offline_ui.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../gallery/presentation/gallery_albums_grouped_view.dart';
import '../../profile/presentation/custom_album_dialog.dart';
import 'child_gallery_album_screen.dart';

/// Галерея ребёнка: та же вёрстка, что у Profile/Family gallery.
class ChildGalleryTab extends ConsumerStatefulWidget {
  const ChildGalleryTab({
    super.key,
    required this.childId,
    this.isCustodian = false,
  });

  final int childId;
  final bool isCustodian;

  @override
  ConsumerState<ChildGalleryTab> createState() => ChildGalleryTabState();
}

class ChildGalleryTabState extends ConsumerState<ChildGalleryTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _albums = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> refresh() => _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final albums = await ref
          .read(familychatRepositoryProvider)
          .childGalleryAlbums(widget.childId);
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = OfflineUi.loadErrorMessage(
          e,
          fallback: 'Не удалось загрузить альбомы',
        );
      });
    }
  }

  int? _customAlbumPk(Map<String, dynamic> album) {
    if (album['kind']?.toString() != 'custom') return null;
    final pk = album['album_pk'];
    if (pk is int) return pk;
    final id = album['id']?.toString() ?? '';
    if (!id.startsWith('custom:')) return null;
    return int.tryParse(id.substring(7));
  }

  Future<bool> createAlbum() async {
    if (!widget.isCustodian) return false;
    final created = await CustomAlbumDialog.show(
      context,
      userId: 0,
      childId: widget.childId,
      initialAddMode: 'all',
    );
    if (created == true) {
      await _load();
      return true;
    }
    return false;
  }

  Future<void> _editAlbum(Map<String, dynamic> album) async {
    final pk = _customAlbumPk(album);
    if (pk == null) return;
    final accessIds = (album['access_user_ids'] as List<dynamic>? ?? [])
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
    final addIds = (album['add_user_ids'] as List<dynamic>? ?? [])
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
    final updated = await CustomAlbumDialog.show(
      context,
      userId: 0,
      childId: widget.childId,
      albumPk: pk,
      initialTitle: album['title']?.toString() ?? '',
      initialAccessMode: album['access_mode']?.toString() ?? 'all',
      initialAccessUserIds: accessIds,
      initialAddMode: album['add_mode']?.toString() ?? 'all',
      initialAddUserIds: addIds,
    );
    if (updated == true) await _load();
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
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(familychatRepositoryProvider)
          .deleteChildCustomAlbum(widget.childId, pk);
      if (mounted) await _load();
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
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
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

  Future<void> _openAlbum(Map<String, dynamic> album) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChildGalleryAlbumScreen(
          childId: widget.childId,
          albumId: album['id']?.toString() ?? 'all',
          title: album['title']?.toString() ?? 'Альбом',
          canManage: album['can_manage'] == true,
          canAddPhotos: album['can_add'] == true || widget.isCustodian,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const DeferredPlaceholder(
        child: Center(child: CircularProgressIndicator()),
      );
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
      body: SafeArea(
        child: GalleryAlbumsGroupedView(
          albums: _albums,
          userId: 0,
          onRefresh: _load,
          onOpenAlbum: _openAlbum,
          onAlbumLongPress: widget.isCustodian ? _showAlbumMenu : null,
          customTabLabel: 'Альбомы',
          alwaysShowCustomGroup: true,
        ),
      ),
      floatingActionButton: widget.isCustodian
          ? FloatingActionButton.extended(
              onPressed: createAlbum,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Альбом'),
            )
          : null,
    );
  }
}
