import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../gallery/presentation/gallery_albums_grouped_view.dart';
import '../../profile/presentation/custom_album_dialog.dart';

class FamilyGalleryTab extends ConsumerStatefulWidget {
  const FamilyGalleryTab({
    super.key,
    required this.currentUserId,
    this.excludeUploadedByUserId,
    this.allowCreateAlbum = true,
  });

  final int currentUserId;
  final int? excludeUploadedByUserId;
  final bool allowCreateAlbum;

  @override
  ConsumerState<FamilyGalleryTab> createState() => FamilyGalleryTabState();
}

class FamilyGalleryTabState extends ConsumerState<FamilyGalleryTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _albums = [];
  String _faceHintMessage = '';
  bool _showFaceHint = false;

  List<Map<String, dynamic>> _filterCommonAlbums(
      List<Map<String, dynamic>> albums) {
    final excludedUserId = widget.excludeUploadedByUserId;
    if (excludedUserId == null) return albums;
    return albums.where((album) {
      final kind = album['kind']?.toString() ?? '';
      final id = album['id']?.toString() ?? '';
      final ownerId = album['owner_user_id'] is int
          ? album['owner_user_id'] as int
          : int.tryParse('${album['owner_user_id']}');
      if (kind == 'custom' && ownerId == excludedUserId) return false;
      if (id == 'face:$excludedUserId') return false;
      return true;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Обновить список альбомов (например при возврате на вкладку).
  Future<void> refresh({bool silent = false}) => _load(silent: silent);

  Future<void> _load({bool silent = false}) async {
    final cached = await FamilyChatLocalCache.readFamilyAlbums();
    if (cached != null && mounted) {
      setState(() {
        final raw = (cached['albums'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        _albums = _filterCommonAlbums(raw);
        _faceHintMessage = cached['face_hint_message']?.toString() ?? '';
        _showFaceHint = cached['show_face_hint'] == true;
        _loading = false;
        _error = null;
      });
    } else if (!silent || _albums.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data =
          await ref.read(familychatRepositoryProvider).familyGalleryAlbums();
      await FamilyChatLocalCache.saveFamilyAlbums(data);
      if (!mounted) return;
      setState(() {
        final raw = (data['albums'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        _albums = _filterCommonAlbums(raw);
        _faceHintMessage = data['face_hint_message']?.toString() ?? '';
        _showFaceHint = data['show_face_hint'] == true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (cached == null) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _createAlbum() async {
    final created = await CustomAlbumDialog.show(
      context,
      userId: widget.currentUserId,
    );
    if (created == true) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Повторить')),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: GalleryAlbumsGroupedView(
          albums: _albums,
          userId: widget.currentUserId,
          isFamilyGallery: true,
          onRefresh: _load,
          faceHintMessage: _faceHintMessage,
          showFaceHint: _showFaceHint,
          excludeUploadedByUserId: widget.excludeUploadedByUserId,
          customTabLabel: 'Альбомы',
        ),
      ),
      floatingActionButton: widget.allowCreateAlbum
          ? FloatingActionButton.extended(
              onPressed: _createAlbum,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Альбом'),
            )
          : null,
    );
  }
}
