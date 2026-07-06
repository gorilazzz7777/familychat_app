import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import 'profile_gallery_album_screen.dart';

class ProfileGalleryTab extends ConsumerStatefulWidget {
  const ProfileGalleryTab({
    super.key,
    required this.userId,
  });

  final int userId;

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

  IconData _albumIcon(String? kind) {
    return switch (kind) {
      'year' => Icons.calendar_today_outlined,
      'place' => Icons.place_outlined,
      'face' => Icons.face_outlined,
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

    return RefreshIndicator(
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
                    return _AlbumCard(
                      album: album,
                      icon: _albumIcon(album['kind']?.toString()),
                      userId: widget.userId,
                    );
                  },
                  childCount: _albums.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AlbumCard extends ConsumerWidget {
  const _AlbumCard({
    required this.album,
    required this.icon,
    required this.userId,
  });

  final Map<String, dynamic> album;
  final IconData icon;
  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final title = album['title']?.toString() ?? '';
    final count = album['count']?.toString() ?? '0';
    final albumId = album['id']?.toString() ?? '';
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
                    ),
                  ),
                );
              },
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
