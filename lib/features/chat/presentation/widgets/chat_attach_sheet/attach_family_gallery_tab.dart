import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/media/media_local_index.dart';
import '../../../../../core/providers/app_providers.dart';
import '../../../../../core/widgets/app_skeletons.dart';
import '../../../../gallery/data/gallery_diary_album_bridge.dart';
import '../../../../gallery/presentation/gallery_media_thumbnail.dart';
import '../../../../members/presentation/utils/milestone_photo_add_trace.dart';
import 'already_in_album_badge.dart';

/// Выбор уже загруженных фото семьи (альбомы + сетка).
class AttachFamilyGalleryTab extends ConsumerStatefulWidget {
  const AttachFamilyGalleryTab({
    super.key,
    required this.userId,
    required this.selected,
    required this.onSelectedChanged,
    required this.scrollController,
    this.excludeAttachmentIds = const {},
    this.childId,
    this.childName,
    this.excludeAlbumId,
    this.onLinkIdMapUpdate,
  });

  final int userId;
  final Set<int> selected;
  final ValueChanged<Set<int>> onSelectedChanged;
  final ScrollController scrollController;
  final Set<int> excludeAttachmentIds;
  final int? childId;
  final String? childName;
  final String? excludeAlbumId;
  final ValueChanged<Map<int, int>>? onLinkIdMapUpdate;

  @override
  ConsumerState<AttachFamilyGalleryTab> createState() =>
      _AttachFamilyGalleryTabState();
}

class _AttachFamilyGalleryTabState
    extends ConsumerState<AttachFamilyGalleryTab> {
  static const _pageSize = 60;

  final List<Map<String, dynamic>> _albums = [];
  final List<Map<String, dynamic>> _photos = [];
  Map<String, dynamic>? _openAlbum;
  bool _loadingAlbums = true;
  bool _loadingPhotos = false;
  bool _loadingMore = false;
  String? _error;
  int _offset = 0;
  int _total = 0;
  int? _beforeId;

  bool get _traceMilestoneFlow => widget.onLinkIdMapUpdate != null;

  bool get _inAlbumView => _openAlbum != null;

  @override
  void initState() {
    super.initState();
    _loadAlbums();
  }

  bool _albumExcluded(Map<String, dynamic> album) {
    final exclude = widget.excludeAlbumId?.trim();
    if (exclude == null || exclude.isEmpty) return false;
    final id = album['id']?.toString() ?? '';
    if (id == exclude) return true;
    final pk = album['album_pk'];
    if (pk != null && exclude == 'custom:$pk') return true;
    return false;
  }

  String _albumSource(Map<String, dynamic> album) =>
      album['_pickerSource']?.toString() ?? 'member';

  int? _albumChildId(Map<String, dynamic> album) {
    final raw = album['_pickerChildId'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _loadingAlbums = true;
      _error = null;
      _albums.clear();
    });
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final memberData = await repo.memberGalleryAlbums(widget.userId);
      final memberAlbums = galleryAlbumMapsOf(memberData['albums']);
      for (final album in memberAlbums) {
        album['_pickerSource'] = 'member';
      }

      final merged = <Map<String, dynamic>>[...memberAlbums];

      final childId = widget.childId;
      if (childId != null) {
        final childAlbums = await repo.childGalleryAlbums(childId);
        final childLabel = (widget.childName?.trim().isNotEmpty == true)
            ? widget.childName!.trim()
            : 'Ребёнок';
        for (final album in childAlbums) {
          album['_pickerSource'] = 'child';
          album['_pickerChildId'] = childId;
          final title = album['title']?.toString().trim();
          if (title != null && title.isNotEmpty) {
            album['title'] = '$childLabel: $title';
          }
        }
        merged.addAll(childAlbums);
      }

      if (!mounted) return;
      setState(() {
        _albums
          ..clear()
          ..addAll(merged.where((a) => !_albumExcluded(a)));
        _loadingAlbums = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingAlbums = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openAlbumView(Map<String, dynamic> album) async {
    if (_traceMilestoneFlow) {
      MilestonePhotoAddTrace.fields('gallery.openAlbum', {
        'albumId': album['id'],
        'title': album['title'],
        'source': _albumSource(album),
        'childId': _albumChildId(album),
      });
    }
    setState(() {
      _openAlbum = album;
      _photos.clear();
      _offset = 0;
      _beforeId = null;
      _total = 0;
      _error = null;
    });
    await _loadPhotos(reset: true);
  }

  void _closeAlbumView() {
    setState(() {
      _openAlbum = null;
      _photos.clear();
      _offset = 0;
      _beforeId = null;
      _total = 0;
      _error = null;
    });
  }

  Future<void> _loadPhotos({required bool reset}) async {
    final album = _openAlbum;
    if (album == null) return;
    if (reset) {
      setState(() {
        _loadingPhotos = true;
        _error = null;
        _offset = 0;
        _beforeId = null;
        _photos.clear();
      });
    } else {
      if (_loadingMore) return;
      if (_albumSource(album) == 'child') {
        if (!_hasMoreChildPhotos) return;
      } else if (_photos.length >= _total && _total > 0) {
        return;
      }
      setState(() => _loadingMore = true);
    }

    try {
      final repo = ref.read(familychatRepositoryProvider);
      final albumId = album['id']?.toString() ?? 'all';
      if (_traceMilestoneFlow) {
        MilestonePhotoAddTrace.fields('gallery.loadPhotos', {
          'reset': reset,
          'albumId': albumId,
          'source': _albumSource(album),
          'childId': _albumChildId(album),
        });
      }
      List<Map<String, dynamic>> batch;
      if (_albumSource(album) == 'child') {
        final childId = _albumChildId(album);
        if (childId == null) {
          batch = const [];
        } else {
          final data = await repo.childGalleryPhotos(
            childId,
            albumId: albumId == 'all' ? null : albumId,
            limit: _pageSize,
            beforeId: reset ? null : _beforeId,
            offset: reset ? 0 : _photos.length,
          );
          batch = (data['photos'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
        }
      } else {
        final data = await repo.memberGalleryPhotos(
          widget.userId,
          albumId,
          offset: reset ? 0 : _offset,
          limit: _pageSize,
        );
        batch = (data['photos'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        if (reset) {
          _total = data['total'] is int
              ? data['total'] as int
              : int.tryParse('${data['total']}') ?? 0;
        }
      }

      await MediaLocalIndex.ensureLoaded();
      MediaLocalIndex.hydrateAttachments(batch);
      if (_traceMilestoneFlow) {
        MilestonePhotoAddTrace.galleryBatch(
          'gallery.loadPhotos',
          source: _albumSource(album),
          photos: batch,
        );
      }
      _publishLinkIds(batch);
      if (!mounted) return;
      setState(() {
        if (reset) {
          _photos
            ..clear()
            ..addAll(batch);
        } else {
          _photos.addAll(batch);
        }
        if (_albumSource(album) != 'child') {
          _offset += batch.length;
        } else if (batch.isNotEmpty) {
          _beforeId = _photoId(batch.last);
        }
        _loadingPhotos = false;
        _loadingMore = false;
      });
    } catch (e, st) {
      if (_traceMilestoneFlow) {
        MilestonePhotoAddTrace.error('gallery.loadPhotos', e, st);
      }
      if (!mounted) return;
      setState(() {
        _loadingPhotos = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  bool get _hasMoreChildPhotos {
    if (_photos.isEmpty) return false;
    return _photos.length % _pageSize == 0 && _photos.length >= _pageSize;
  }

  int? _photoId(Map<String, dynamic> photo) {
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  int? _diaryLinkId(Map<String, dynamic> photo) {
    final raw = photo['diary_attachment_id'];
    if (raw is int) return raw;
    return int.tryParse('${raw ?? ''}');
  }

  void _publishLinkIds(List<Map<String, dynamic>> batch) {
    final cb = widget.onLinkIdMapUpdate;
    if (cb == null || batch.isEmpty) return;
    final map = <int, int>{};
    for (final photo in batch) {
      final fcId = _photoId(photo);
      if (fcId == null) continue;
      map[fcId] = _diaryLinkId(photo) ?? fcId;
    }
    if (map.isNotEmpty) {
      if (_traceMilestoneFlow) {
        MilestonePhotoAddTrace.linkMap('gallery.publishLinkIds', map);
      }
      cb(map);
    }
  }

  bool _photoExcluded(Map<String, dynamic> photo) {
    final fcId = _photoId(photo);
    if (fcId != null && widget.excludeAttachmentIds.contains(fcId)) {
      return true;
    }
    final diaryId = _diaryLinkId(photo);
    if (diaryId != null && widget.excludeAttachmentIds.contains(diaryId)) {
      return true;
    }
    return false;
  }

  List<int> get _selectablePhotoIds => _photos
      .where((photo) => !_photoExcluded(photo))
      .map(_photoId)
      .whereType<int>()
      .toList();

  bool get _allPhotosSelected {
    final ids = _selectablePhotoIds;
    return ids.isNotEmpty && ids.every(widget.selected.contains);
  }

  void _toggleSelectAll() {
    final ids = _selectablePhotoIds;
    final next = Set<int>.from(widget.selected);
    if (_allPhotosSelected) {
      next.removeAll(ids);
    } else {
      next.addAll(ids);
    }
    widget.onSelectedChanged(next);
  }

  void _toggle(int photoId) {
    final next = Set<int>.from(widget.selected);
    final added = next.add(photoId);
    if (!added) next.remove(photoId);
    if (_traceMilestoneFlow) {
      Map<String, dynamic>? photo;
      for (final p in _photos) {
        if (_photoId(p) == photoId) {
          photo = p;
          break;
        }
      }
      MilestonePhotoAddTrace.fields('gallery.toggle', {
        'fcId': photoId,
        'selected': added,
        'diaryId': photo == null ? null : _diaryLinkId(photo),
        'excluded': photo == null ? null : _photoExcluded(photo),
      });
    }
    widget.onSelectedChanged(next);
  }

  bool _inCustomAlbums(Map<String, dynamic> photo) {
    final value = photo['in_custom_albums'];
    return value == true || value == 1 || value == 'true';
  }

  Widget _buildAlbumTile(Map<String, dynamic> album) {
    final title = album['title']?.toString().trim();
    final count = album['count'] ?? album['photos_count'];
    return ListTile(
      leading: const Icon(Icons.photo_album_outlined),
      title: Text(title?.isNotEmpty == true ? title! : 'Альбом'),
      subtitle: Text(
        _albumSource(album) == 'child' ? 'Галерея ребёнка' : 'Моя галерея',
      ),
      trailing: count == null ? null : Text('$count'),
      onTap: () => _openAlbumView(album),
    );
  }

  Widget _buildAlbumList() {
    if (_loadingAlbums) {
      return const DeferredPlaceholder(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_albums.isEmpty) {
      return const Center(child: Text('Нет доступных альбомов'));
    }
    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: _albums.length,
      itemBuilder: (_, i) => _buildAlbumTile(_albums[i]),
    );
  }

  Widget _buildPhotoGrid() {
    if (_loadingPhotos) {
      return const DeferredPlaceholder(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_photos.isEmpty) {
      return const Center(child: Text('В альбоме нет фото'));
    }

    final album = _openAlbum!;
    final useChildPagination = _albumSource(album) == 'child';
    final hasMore = useChildPagination
        ? _hasMoreChildPhotos
        : _photos.length < _total;

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200 &&
            !_loadingMore &&
            hasMore) {
          _loadPhotos(reset: false);
        }
        return false;
      },
      child: GridView.builder(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: _photos.length + (_loadingMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= _photos.length) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final photo = _photos[i];
          final photoId = _photoId(photo);
          final threadId = photo['thread_id'];
          if (photoId == null || threadId is! int) {
            return const ColoredBox(color: Color(0x22000000));
          }
          final alreadyHere = _photoExcluded(photo);
          final inAlbums = _inCustomAlbums(photo);
          final selected = widget.selected.contains(photoId);
          return GestureDetector(
            onTap: alreadyHere ? null : () => _toggle(photoId),
            child: Stack(
              fit: StackFit.expand,
              children: [
                GalleryMediaThumbnail(
                  attachment: photo,
                  threadId: threadId,
                  fit: BoxFit.cover,
                ),
                if (alreadyHere)
                  const ColoredBox(
                    color: Color(0x66000000),
                    child: Center(
                      child: Icon(Icons.check, color: Colors.white70),
                    ),
                  )
                else if (inAlbums)
                  const Positioned(
                    left: 6,
                    top: 6,
                    child: AlreadyInAlbumBadge(),
                  ),
                if (!alreadyHere && selected)
                  Container(
                    color: Colors.black38,
                    child: const Icon(
                      Icons.check_circle,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final albumTitle = _openAlbum?['title']?.toString() ?? 'Альбом';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            children: [
              if (_inAlbumView)
                IconButton(
                  tooltip: 'Назад',
                  onPressed: _closeAlbumView,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  _inAlbumView ? albumTitle : 'Альбомы семьи',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_inAlbumView)
                TextButton(
                  onPressed:
                      _selectablePhotoIds.isEmpty ? null : _toggleSelectAll,
                  child: Text(_allPhotosSelected ? 'Снять все' : 'Выбрать все'),
                ),
            ],
          ),
        ),
        Expanded(
          child: _inAlbumView ? _buildPhotoGrid() : _buildAlbumList(),
        ),
      ],
    );
  }
}
