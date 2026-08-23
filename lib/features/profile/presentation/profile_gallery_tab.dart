import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/network/offline_ui.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../gallery/presentation/gallery_albums_grouped_view.dart';
import '../../gallery/presentation/gallery_albums_tab_body.dart';
import 'custom_album_dialog.dart';

class ProfileGalleryTab extends ConsumerStatefulWidget {
  const ProfileGalleryTab({
    super.key,
    required this.userId,
    this.isOwnGallery = false,
  });

  final int userId;
  final bool isOwnGallery;

  @override
  ConsumerState<ProfileGalleryTab> createState() => ProfileGalleryTabState();
}

class ProfileGalleryTabState extends ConsumerState<ProfileGalleryTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _albums = [];
  String _faceHintMessage = '';
  bool _showFaceHint = false;
  int _loadGen = 0;
  Future<void>? _loadInFlight;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (_loadInFlight != null) {
      return _loadInFlight!;
    }
    final future = _loadBody(silent: silent);
    _loadInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_loadInFlight, future)) {
        _loadInFlight = null;
      }
    }
  }

  Future<void> _loadBody({bool silent = false}) async {
    final gen = ++_loadGen;
    final cached = await FamilyChatLocalCache.readMemberAlbums(widget.userId);
    if (gen != _loadGen || !mounted) return;
    if (cached != null) {
      final next = galleryAlbumsAsMaps(cached['albums']);
      final hint = cached['face_hint_message']?.toString() ?? '';
      final showHint = cached['show_face_hint'] == true;
      if (galleryAlbumsFingerprint(_albums) != galleryAlbumsFingerprint(next) ||
          _faceHintMessage != hint ||
          _showFaceHint != showHint ||
          _loading) {
        setState(() {
          _albums = next;
          _faceHintMessage = hint;
          _showFaceHint = showHint;
          _loading = false;
          _error = null;
        });
      }
    } else if (!silent && _albums.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .memberGalleryAlbums(widget.userId);
      if (gen != _loadGen || !mounted) return;
      await FamilyChatLocalCache.saveMemberAlbums(widget.userId, data);
      final next = galleryAlbumsAsMaps(data['albums']);
      final hint = data['face_hint_message']?.toString() ?? '';
      final showHint = data['show_face_hint'] == true;
      if (galleryAlbumsFingerprint(_albums) == galleryAlbumsFingerprint(next) &&
          _faceHintMessage == hint &&
          _showFaceHint == showHint &&
          !_loading) {
        return;
      }
      setState(() {
        _albums = next;
        _faceHintMessage = hint;
        _showFaceHint = showHint;
        _loading = false;
      });
    } catch (e) {
      if (gen != _loadGen || !mounted) return;
      if (cached == null) {
        setState(() {
          _loading = false;
          _error = OfflineUi.loadErrorMessage(
            e,
            fallback: 'Не удалось загрузить альбомы',
          );
        });
      }
    }
  }

  Future<bool> createAlbum() async {
    final created = await CustomAlbumDialog.show(
      context,
      userId: widget.userId,
    );
    if (created == true) {
      await _load();
      return true;
    }
    return false;
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
    final addIds = (album['add_user_ids'] as List<dynamic>? ?? [])
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
      initialAddMode: album['add_mode']?.toString() ?? 'owner',
      initialAddUserIds: addIds,
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
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
          userId: widget.userId,
          isOwnGallery: widget.isOwnGallery,
          onRefresh: () => _load(silent: _albums.isNotEmpty),
          faceHintMessage: _faceHintMessage,
          showFaceHint: _showFaceHint,
          onAlbumLongPress: widget.isOwnGallery ? _showAlbumMenu : null,
          customTabLabel: 'Мои альбомы',
        ),
      ),
    );
  }
}
