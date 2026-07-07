import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import '../../profile/presentation/custom_album_dialog.dart';
import '../../profile/presentation/profile_gallery_album_screen.dart';

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
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_showFaceHint && _faceHintMessage.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_faceHintMessage),
                    ),
                  ),
                ),
              ),
            if (_albums.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('Нет доступных фото')),
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
                      return _FamilyAlbumCard(
                        album: album,
                        icon: _albumIcon(album['kind']?.toString()),
                        userId: widget.currentUserId,
                      );
                    },
                    childCount: _albums.length,
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createAlbum,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Альбом'),
      ),
    );
  }
}

class _FamilyAlbumCard extends StatelessWidget {
  const _FamilyAlbumCard({
    required this.album,
    required this.icon,
    required this.userId,
  });

  final Map<String, dynamic> album;
  final IconData icon;
  final int userId;

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
            : () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProfileGalleryAlbumScreen(
                      userId: userId,
                      albumId: albumId,
                      title: title,
                      canManage: canManage,
                      isFamilyGallery: true,
                    ),
                  ),
                );
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: cover != null && cover['thread_id'] != null
                  ? ChatNetworkImage(
                      threadId: cover['thread_id'] is int
                          ? cover['thread_id'] as int
                          : int.tryParse('${cover['thread_id']}') ?? 0,
                      attachment: cover,
                      fit: BoxFit.cover,
                    )
                  : Center(child: Icon(icon, size: 40, color: theme.colorScheme.primary)),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  Text('$count фото', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
