import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../gallery/presentation/gallery_albums_grouped_view.dart';
import '../../profile/presentation/custom_album_dialog.dart';

class FamilyGalleryTab extends ConsumerStatefulWidget {
  const FamilyGalleryTab({super.key, required this.currentUserId});

  final int currentUserId;

  @override
  ConsumerState<FamilyGalleryTab> createState() => _FamilyGalleryTabState();
}

class _FamilyGalleryTabState extends ConsumerState<FamilyGalleryTab> {
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
    final cached = await FamilyChatLocalCache.readFamilyAlbums();
    if (cached != null && mounted) {
      setState(() {
        _albums = (cached['albums'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _faceHintMessage = cached['face_hint_message']?.toString() ?? '';
        _showFaceHint = cached['show_face_hint'] == true;
        _loading = false;
        _error = null;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await ref.read(familychatRepositoryProvider).familyGalleryAlbums();
      await FamilyChatLocalCache.saveFamilyAlbums(data);
      if (!mounted) return;
      setState(() {
        _albums = (data['albums'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
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
      body: GalleryAlbumsGroupedView(
        albums: _albums,
        userId: widget.currentUserId,
        isFamilyGallery: true,
        onRefresh: _load,
        faceHintMessage: _faceHintMessage,
        showFaceHint: _showFaceHint,
        customTabLabel: 'Альбомы',
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createAlbum,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Альбом'),
      ),
    );
  }
}
