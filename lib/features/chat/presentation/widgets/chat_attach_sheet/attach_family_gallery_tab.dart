import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/providers/app_providers.dart';
import '../../../../../core/widgets/app_skeletons.dart';
import '../chat_network_image.dart';

/// Выбор уже загруженных фото семьи (для альбома).
class AttachFamilyGalleryTab extends ConsumerStatefulWidget {
  const AttachFamilyGalleryTab({
    super.key,
    required this.userId,
    required this.selected,
    required this.onSelectedChanged,
    required this.scrollController,
    this.excludeAttachmentIds = const {},
  });

  final int userId;
  final Set<int> selected;
  final ValueChanged<Set<int>> onSelectedChanged;
  final ScrollController scrollController;
  final Set<int> excludeAttachmentIds;

  @override
  ConsumerState<AttachFamilyGalleryTab> createState() =>
      _AttachFamilyGalleryTabState();
}

class _AttachFamilyGalleryTabState
    extends ConsumerState<AttachFamilyGalleryTab> {
  final List<Map<String, dynamic>> _photos = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _offset = 0;
  int _total = 0;
  static const _pageSize = 60;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _offset = 0;
        _photos.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final data =
          await ref.read(familychatRepositoryProvider).memberGalleryPickablePhotos(
                widget.userId,
                offset: _offset,
                limit: _pageSize,
              );
      if (!mounted) return;
      final batch =
          (data['photos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _total = data['total'] is int
            ? data['total'] as int
            : int.tryParse('${data['total']}') ?? 0;
        _photos.addAll(batch);
        _offset += batch.length;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  int? _photoId(Map<String, dynamic> photo) {
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  List<int> get _selectablePhotoIds => _photos
      .map(_photoId)
      .whereType<int>()
      .where((id) => !widget.excludeAttachmentIds.contains(id))
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
    if (!next.add(photoId)) next.remove(photoId);
    widget.onSelectedChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Фото семьи',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              TextButton(
                onPressed:
                    _selectablePhotoIds.isEmpty ? null : _toggleSelectAll,
                child: Text(_allPhotosSelected ? 'Снять все' : 'Выбрать все'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const DeferredPlaceholder(
                  child: Center(child: CircularProgressIndicator()),
                )
              : _error != null
                  ? Center(child: Text(_error!))
                  : _photos.isEmpty
                      ? const Center(child: Text('Нет доступных фото'))
                      : NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n.metrics.pixels >=
                                    n.metrics.maxScrollExtent - 200 &&
                                !_loadingMore &&
                                _photos.length < _total) {
                              _load(reset: false);
                            }
                            return false;
                          },
                          child: GridView.builder(
                            controller: widget.scrollController,
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                            ),
                            itemCount: _photos.length + (_loadingMore ? 1 : 0),
                            itemBuilder: (_, i) {
                              if (i >= _photos.length) {
                                return const Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                );
                              }
                              final photo = _photos[i];
                              final photoId = _photoId(photo);
                              final threadId = photo['thread_id'];
                              if (photoId == null || threadId is! int) {
                                return const ColoredBox(
                                  color: Color(0x22000000),
                                );
                              }
                              if (widget.excludeAttachmentIds
                                  .contains(photoId)) {
                                return const ColoredBox(
                                  color: Color(0x33000000),
                                  child: Center(
                                    child: Icon(
                                      Icons.check,
                                      color: Colors.white70,
                                    ),
                                  ),
                                );
                              }
                              final selected =
                                  widget.selected.contains(photoId);
                              return GestureDetector(
                                onTap: () => _toggle(photoId),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ChatNetworkImage(
                                      threadId: threadId,
                                      attachment: photo,
                                      fit: BoxFit.cover,
                                    ),
                                    if (selected)
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
                        ),
        ),
      ],
    );
  }
}
