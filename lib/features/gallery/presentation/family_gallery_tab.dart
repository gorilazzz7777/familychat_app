import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/network/offline_ui.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../gallery/presentation/gallery_albums_grouped_view.dart';
import '../../gallery/presentation/gallery_albums_tab_body.dart';
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

class FamilyGalleryTabState extends ConsumerState<FamilyGalleryTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _albums = [];
  String _faceHintMessage = '';
  bool _showFaceHint = false;
  int _loadGen = 0;
  Future<void>? _loadInFlight;

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

  Future<void> _loadBody({required bool silent}) async {
    final gen = ++_loadGen;
    final cached = await FamilyChatLocalCache.readFamilyAlbums();
    if (gen != _loadGen || !mounted) return;
    if (cached != null) {
      final next = _filterCommonAlbums(galleryAlbumsAsMaps(cached['albums']));
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
      final data =
          await ref.read(familychatRepositoryProvider).familyGalleryAlbums();
      if (gen != _loadGen || !mounted) return;
      await FamilyChatLocalCache.saveFamilyAlbums(data);
      final next = _filterCommonAlbums(galleryAlbumsAsMaps(data['albums']));
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
        _error = null;
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
          onRefresh: () => _load(silent: _albums.isNotEmpty),
          faceHintMessage: _faceHintMessage,
          showFaceHint: _showFaceHint,
          excludeUploadedByUserId: widget.excludeUploadedByUserId,
          customTabLabel: 'Альбомы',
          alwaysShowCustomGroup: true,
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
