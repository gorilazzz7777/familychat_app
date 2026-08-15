import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/media/media_incoming_sync.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_models.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_sheet.dart';
import '../../gallery/presentation/gallery_media_thumbnail.dart';
import '../../gallery/presentation/widgets/gallery_mosaic_layout.dart';
import '../../profile/presentation/custom_album_dialog.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';

/// Альбом галереи ребёнка: шахматная мозаика + FAB добавления (с sync Dairy).
class ChildGalleryAlbumScreen extends ConsumerStatefulWidget {
  const ChildGalleryAlbumScreen({
    super.key,
    required this.childId,
    required this.albumId,
    required this.title,
    this.canManage = false,
    this.canAddPhotos = false,
  });

  final int childId;
  final String albumId;
  final String title;
  final bool canManage;
  final bool canAddPhotos;

  bool get isCustomAlbum => albumId.startsWith('custom:');

  int? get customAlbumPk {
    if (!isCustomAlbum) return null;
    return int.tryParse(albumId.substring(7));
  }

  @override
  ConsumerState<ChildGalleryAlbumScreen> createState() =>
      _ChildGalleryAlbumScreenState();
}

class _ChildGalleryAlbumScreenState
    extends ConsumerState<ChildGalleryAlbumScreen> {
  final List<Map<String, dynamic>> _photos = [];
  final Set<int> _selectedPhotoIds = {};
  bool _loading = true;
  bool _loadingMore = false;
  bool _addingPhotos = false;
  bool _selectionMode = false;
  bool _hasMore = true;
  String? _error;
  int? _beforeId;
  int? _currentUserId;
  static const _pageSize = 60;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrentUserId());
    unawaited(_load(reset: true));
  }

  Future<void> _loadCurrentUserId() async {
    try {
      final status = await ref.read(familychatRepositoryProvider).status();
      final userId = status['user_id'];
      if (!mounted) return;
      setState(() {
        _currentUserId =
            userId is int ? userId : int.tryParse('$userId');
      });
    } catch (_) {}
  }

  int? _photoId(Map<String, dynamic> photo) {
    final id = photo['id'];
    return id is int ? id : int.tryParse('$id');
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _beforeId = null;
        _hasMore = true;
        _photos.clear();
      });
    } else {
      if (!_hasMore || _loadingMore) return;
      setState(() => _loadingMore = true);
    }
    try {
      final gallery =
          await ref.read(familychatRepositoryProvider).childGalleryPhotos(
                widget.childId,
                albumId: widget.albumId == 'all' ? null : widget.albumId,
                limit: _pageSize,
                beforeId: reset ? null : _beforeId,
              );
      if (!mounted) return;
      final batch = (gallery['photos'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      MediaLocalIndex.hydrateAttachments(batch);
      unawaited(MediaIncomingSync.ensureGalleryPhotos(batch));
      setState(() {
        if (reset) {
          _photos
            ..clear()
            ..addAll(batch);
        } else {
          _photos.addAll(batch);
        }
        if (batch.isNotEmpty) {
          _beforeId = _photoId(batch.last);
        }
        _hasMore = batch.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset) _error = 'Не удалось загрузить фото';
      });
    }
  }

  Future<void> _showAddPhotosSheet() async {
    if (!widget.canAddPhotos || _addingPhotos) return;
    await ChatAttachSheet.show(
      context,
      style: ChatAttachSheetStyle.phoneMedia,
      onSendMedia: (caption, items) async {
        await _uploadItems(items);
      },
    );
  }

  Future<void> _uploadItems(List<ChatAttachSelectionItem> items) async {
    if (items.isEmpty) return;
    setState(() => _addingPhotos = true);
    final repo = ref.read(familychatRepositoryProvider);
    var ok = 0;
    var fail = 0;
    try {
      for (final item in items) {
        if (item.kind != 'image' && item.kind != 'video') continue;
        try {
          final uploaded = await repo.childGalleryUpload(
            childId: widget.childId,
            bytes: item.bytes,
            filename: item.filename,
            contentType: item.contentType,
            albumPk: widget.customAlbumPk,
          );
          final id = uploaded['id'];
          final attachmentId = id is int ? id : int.tryParse('$id');
          final localPath = item.localPath?.trim() ?? '';
          if (attachmentId != null && localPath.isNotEmpty) {
            await MediaLocalIndex.saveOutgoing(
              attachmentId: attachmentId,
              localPath: localPath,
              filename: item.filename,
              kind: item.kind,
            );
          }
          ok++;
        } catch (_) {
          fail++;
        }
      }
      await _load(reset: true);
      if (!mounted) return;
      final msg = fail == 0
          ? 'Добавлено: $ok'
          : 'Добавлено: $ok, ошибок: $fail';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _addingPhotos = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedPhotoIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить фото?'),
        content: Text(
          'Будет удалено ${_selectedPhotoIds.length} фото (и в Dairy).',
        ),
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
    final repo = ref.read(familychatRepositoryProvider);
    for (final id in _selectedPhotoIds.toList()) {
      try {
        await repo.deleteChildGalleryPhoto(
          childId: widget.childId,
          attachmentId: id,
        );
      } catch (_) {}
    }
    setState(() {
      _selectionMode = false;
      _selectedPhotoIds.clear();
    });
    await _load(reset: true);
  }

  Future<void> _removeSelectedFromAlbum() async {
    final pk = widget.customAlbumPk;
    if (pk == null || _selectedPhotoIds.isEmpty) return;
    final repo = ref.read(familychatRepositoryProvider);
    for (final id in _selectedPhotoIds.toList()) {
      try {
        await repo.removePhotoFromChildCustomAlbum(
          childId: widget.childId,
          albumPk: pk,
          attachmentId: id,
        );
      } catch (_) {}
    }
    setState(() {
      _selectionMode = false;
      _selectedPhotoIds.clear();
    });
    await _load(reset: true);
  }

  Future<void> _editAlbum() async {
    final pk = widget.customAlbumPk;
    if (pk == null || !widget.canManage) return;
    final updated = await CustomAlbumDialog.show(
      context,
      userId: 0,
      childId: widget.childId,
      albumPk: pk,
      initialTitle: widget.title,
      initialAddMode: 'all',
    );
    if (updated == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _deleteAlbum() async {
    final pk = widget.customAlbumPk;
    if (pk == null || !widget.canManage) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить альбом?'),
        content: Text(
          'Альбом «${widget.title}» будет удалён. Фото останутся в галерее.',
        ),
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
    await ref
        .read(familychatRepositoryProvider)
        .deleteChildCustomAlbum(widget.childId, pk);
    if (mounted) Navigator.of(context).pop();
  }

  void _openViewer(int index) {
    final photo = _photos[index];
    final uid = _currentUserId ?? 0;
    GalleryPhotoViewerScreen.open(
      context,
      profileUserId: uid,
      photo: photo,
      currentUserId: uid,
      photos: _photos,
      initialIndex: index,
      onChanged: () => _load(reset: true),
    );
  }

  Widget _thumb(Map<String, dynamic> photo) {
    final threadId = photo['thread_id'];
    final tid = threadId is int ? threadId : int.tryParse('$threadId');
    return GalleryMediaThumbnail(
      attachment: photo,
      threadId: tid,
      fit: BoxFit.cover,
    );
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = widget.canAddPhotos;

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: widget.title,
        actions: [
          if (_selectionMode) ...[
            if (widget.isCustomAlbum && widget.canManage)
              IconButton(
                tooltip: 'Убрать из альбома',
                onPressed: _selectedPhotoIds.isEmpty
                    ? null
                    : _removeSelectedFromAlbum,
                icon: const Icon(Icons.remove_circle_outline),
              ),
            if (widget.canManage)
              IconButton(
                tooltip: 'Удалить',
                onPressed:
                    _selectedPhotoIds.isEmpty ? null : _deleteSelected,
                icon: const Icon(Icons.delete_outline),
              ),
            IconButton(
              onPressed: () => setState(() {
                _selectionMode = false;
                _selectedPhotoIds.clear();
              }),
              icon: const Icon(Icons.close),
            ),
          ] else ...[
            if (widget.canManage)
              IconButton(
                tooltip: 'Выбрать',
                onPressed: () => setState(() => _selectionMode = true),
                icon: const Icon(Icons.checklist_outlined),
              ),
            if (widget.canManage && widget.isCustomAlbum)
              PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      _editAlbum();
                    case 'delete':
                      _deleteAlbum();
                  }
                },
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Редактировать'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Удалить альбом'),
                  ),
                ],
              ),
          ],
        ],
      ),
      floatingActionButton: canAdd && !_selectionMode
          ? FloatingActionButton(
              onPressed: _addingPhotos ? null : _showAddPhotosSheet,
              child: _addingPhotos
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => _load(reset: true),
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                )
              : _photos.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Пока нет фото'),
                          if (canAdd) ...[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _showAddPhotosSheet,
                              icon: const Icon(Icons.add_photo_alternate_outlined),
                              label: const Text('Добавить фото'),
                            ),
                          ],
                        ],
                      ),
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.pixels >
                                n.metrics.maxScrollExtent - 400 &&
                            _hasMore &&
                            !_loadingMore) {
                          unawaited(_load(reset: false));
                        }
                        return false;
                      },
                      child: CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.all(
                              GalleryMosaicLayout.padding,
                            ),
                            sliver: SliverGrid(
                              gridDelegate:
                                  GalleryMosaicLayout.delegate(),
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final photo = _photos[index];
                                  final id = _photoId(photo);
                                  final selected = id != null &&
                                      _selectedPhotoIds.contains(id);
                                  return Material(
                                    clipBehavior: Clip.antiAlias,
                                    borderRadius: BorderRadius.circular(6),
                                    child: InkWell(
                                      onTap: () {
                                        if (_selectionMode) {
                                          if (id == null) return;
                                          setState(() {
                                            if (selected) {
                                              _selectedPhotoIds.remove(id);
                                            } else {
                                              _selectedPhotoIds.add(id);
                                            }
                                          });
                                          return;
                                        }
                                        _openViewer(index);
                                      },
                                      onLongPress: widget.canManage
                                          ? () {
                                              if (id == null) return;
                                              setState(() {
                                                _selectionMode = true;
                                                _selectedPhotoIds.add(id);
                                              });
                                            }
                                          : null,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          _thumb(photo),
                                          if (_selectionMode)
                                            Positioned(
                                              top: 6,
                                              right: 6,
                                              child: Icon(
                                                selected
                                                    ? Icons.check_circle
                                                    : Icons.circle_outlined,
                                                color: selected
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                    : Colors.white,
                                                shadows: const [
                                                  Shadow(
                                                    blurRadius: 4,
                                                    color: Colors.black54,
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                                childCount: _photos.length,
                              ),
                            ),
                          ),
                          if (_loadingMore)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
    );
  }
}
