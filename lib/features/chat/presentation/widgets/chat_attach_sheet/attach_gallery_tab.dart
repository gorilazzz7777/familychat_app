import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../../profile/presentation/album_upload_file_bytes.dart';
import '../../../../profile/presentation/read_picked_image_bytes.dart';
import '../../../../../core/media/gallery_media_utils.dart';
import 'attach_camera_tile.dart';
import 'chat_attach_models.dart';

typedef AttachItemsChanged = void Function(List<ChatAttachSelectionItem> items);

class AttachGalleryTab extends StatefulWidget {
  const AttachGalleryTab({
    super.key,
    required this.selected,
    required this.onSelectedChanged,
    required this.scrollController,
    required this.expanded,
  });

  final List<ChatAttachSelectionItem> selected;
  final AttachItemsChanged onSelectedChanged;
  final ScrollController scrollController;
  final bool expanded;

  @override
  State<AttachGalleryTab> createState() => _AttachGalleryTabState();
}

class _AttachGalleryTabState extends State<AttachGalleryTab> {
  bool _loading = true;
  String? _error;
  bool _limitedAccess = false;
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _album;
  final List<AssetEntity> _assets = [];
  bool _loadingMore = false;
  bool _hasMore = true;
  static const _pageSize = 60;

  final Map<String, int> _selectionOrder = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant AttachGalleryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectionOrder
      ..clear()
      ..addEntries(
        widget.selected.asMap().entries.map(
              (e) => MapEntry(e.value.id, e.key + 1),
            ),
      );
  }

  Future<void> _bootstrap() async {
    if (kIsWeb) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final perm = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.common,
            mediaLocation: true,
          ),
        ),
      );
      if (!perm.isAuth && !perm.hasAccess) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Нет доступа к фото. Разрешите доступ в настройках.';
        });
        return;
      }

      final paths = await _loadAllAlbums();
      AssetPathEntity? preferred;
      for (final p in paths) {
        if (p.isAll) {
          preferred = p;
          break;
        }
      }
      preferred ??= paths.isNotEmpty ? paths.first : null;
      if (!mounted) return;
      setState(() {
        _albums = paths;
        _album = preferred;
        _loading = false;
        _limitedAccess = perm == PermissionState.limited;
      });
      await _reloadAssets();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось открыть галерею';
      });
    }
  }

  Future<List<AssetPathEntity>> _loadAllAlbums() async {
    final filter = FilterOptionGroup(
      imageOption: const FilterOption(
        sizeConstraint: SizeConstraint(ignoreSize: true),
      ),
      videoOption: const FilterOption(
        sizeConstraint: SizeConstraint(ignoreSize: true),
      ),
      orders: [
        const OrderOption(type: OrderOptionType.createDate, asc: false),
      ],
    );

    final byId = <String, AssetPathEntity>{};

    Future<void> addFrom(RequestType type) async {
      final list = await PhotoManager.getAssetPathList(
        type: type,
        hasAll: true,
        onlyAll: false,
        filterOption: filter,
      );
      for (final path in list) {
        byId.putIfAbsent(path.id, () => path);
      }
    }

    await addFrom(RequestType.common);
    await addFrom(RequestType.image);
    await addFrom(RequestType.video);

    final albums = byId.values.toList();
    final withCounts = <({AssetPathEntity path, int count})>[];
    for (final path in albums) {
      try {
        final count = await path.assetCountAsync;
        if (count > 0 || path.isAll) {
          withCounts.add((path: path, count: count));
        }
      } catch (_) {
        withCounts.add((path: path, count: 0));
      }
    }

    withCounts.sort((a, b) {
      if (a.path.isAll != b.path.isAll) return a.path.isAll ? -1 : 1;
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.path.name.toLowerCase().compareTo(b.path.name.toLowerCase());
    });
    return withCounts.map((e) => e.path).toList();
  }

  Future<void> _pickAlbum() async {
    if (_albums.isEmpty) return;
    final chosen = await showModalBottomSheet<AssetPathEntity>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    'Альбомы',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _albums.length,
                    itemBuilder: (context, i) {
                      final album = _albums[i];
                      return FutureBuilder<int>(
                        future: album.assetCountAsync,
                        builder: (context, snap) {
                          final count = snap.data;
                          final title = album.isAll
                              ? (album.name.trim().isEmpty
                                  ? 'Все фото'
                                  : album.name)
                              : album.name;
                          return ListTile(
                            title: Text(title),
                            subtitle: count == null ? null : Text('$count'),
                            trailing: album.id == _album?.id
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => Navigator.pop(ctx, album),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    setState(() => _album = chosen);
    await _reloadAssets();
  }

  Future<void> _reloadAssets() async {
    _assets.clear();
    _hasMore = true;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await album.getAssetListRange(
        start: _assets.length,
        end: _assets.length + _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _assets.addAll(next);
        _hasMore = next.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  bool _isSelected(String id) => widget.selected.any((e) => e.id == id);

  Future<void> _toggleAsset(AssetEntity asset) async {
    final id = 'asset_${asset.id}';
    if (_isSelected(id)) {
      widget.onSelectedChanged(
        widget.selected.where((e) => e.id != id).toList(),
      );
      return;
    }
    final file = await asset.originFile ?? await asset.file;
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    final title = await asset.titleAsync;
    final filename =
        title.isNotEmpty ? title : 'media_${asset.id}.${asset.type == AssetType.video ? 'mp4' : 'jpg'}';
    final thumbData = await asset.thumbnailDataWithSize(
      const ThumbnailSize(200, 200),
    );
    final kind = asset.type == AssetType.video
        ? 'video'
        : (asset.type == AssetType.image ? 'image' : 'file');
    final item = ChatAttachSelectionItem(
      id: id,
      filename: filename,
      bytes: bytes,
      thumbnailBytes: thumbData,
      contentType: contentTypeForFilename(filename),
      localPath: file.path,
      assetId: asset.id,
      kind: kind,
    );
    widget.onSelectedChanged([...widget.selected, item]);
  }

  Future<void> _openCamera() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Фото'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Видео'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;
    final picker = ImagePicker();
    if (mode == 'video') {
      final picked = await picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 30),
      );
      if (picked == null) return;
      final bytes = await readPickedImageBytes(picked);
      if (bytes.isEmpty) return;
      final item = ChatAttachSelectionItem(
        id: 'cam_v_${DateTime.now().microsecondsSinceEpoch}',
        filename: picked.name,
        bytes: bytes,
        contentType: picked.mimeType ?? contentTypeForFilename(picked.name),
        localPath: picked.path,
        kind: 'video',
      );
      widget.onSelectedChanged([...widget.selected, item]);
    } else {
      final picked = await picker.pickImage(
        source: ImageSource.camera,
        requestFullMetadata: true,
      );
      if (picked == null) return;
      final bytes = await readPickedImageBytes(picked);
      if (bytes.isEmpty) return;
      final item = ChatAttachSelectionItem(
        id: 'cam_i_${DateTime.now().microsecondsSinceEpoch}',
        filename: picked.name,
        bytes: bytes,
        contentType: picked.mimeType ?? contentTypeForFilename(picked.name),
        localPath: picked.path,
        kind: 'image',
      );
      widget.onSelectedChanged([...widget.selected, item]);
    }
  }

  Future<void> _webPickGallery() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.media,
      withData: true,
      readSequential: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final next = [...widget.selected];
    for (final f in picked.files) {
      final bytes = await readAlbumUploadFileBytes(f);
      if (bytes == null || bytes.isEmpty) continue;
      final ct = contentTypeForFilename(f.name);
      final kind = ct.startsWith('video/')
          ? 'video'
          : (ct.startsWith('image/') ? 'image' : 'file');
      next.add(
        ChatAttachSelectionItem(
          id: 'web_${f.name}_${bytes.length}_${DateTime.now().microsecondsSinceEpoch}',
          filename: f.name,
          bytes: bytes,
          contentType: ct,
          kind: kind,
        ),
      );
    }
    widget.onSelectedChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (kIsWeb) {
      return ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            height: 120,
            child: Row(
              children: [
                Expanded(
                  child: AttachCameraTile(onTap: _openCamera),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.tonalIcon(
                    onPressed: _webPickGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Выбрать из галереи'),
                  ),
                ),
              ],
            ),
          ),
          if (widget.selected.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Выбрано: ${widget.selected.length}',
              style: theme.textTheme.titleSmall,
            ),
          ],
        ],
      );
    }

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
              FilledButton(onPressed: _bootstrap, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _pickAlbum,
                icon: const Icon(Icons.arrow_drop_down),
                label: Text(
                  _album == null
                      ? 'Галерея'
                      : (_album!.isAll && _album!.name.trim().isEmpty
                          ? 'Все фото'
                          : _album!.name),
                ),
              ),
              const Spacer(),
              if (_limitedAccess)
                TextButton(
                  onPressed: () async {
                    await PhotoManager.presentLimited(type: RequestType.common);
                    await _bootstrap();
                  },
                  child: const Text('Ещё фото'),
                ),
            ],
          ),
        ),
        if (_limitedAccess)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              'Доступ ограничен: видны не все альбомы. Нажмите «Ещё фото» или разрешите полный доступ в настройках.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
                _loadMore();
              }
              return false;
            },
            child: GridView.builder(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: _assets.length + 1 + (_loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return AttachCameraTile(onTap: _openCamera);
                }
                final assetIndex = index - 1;
                if (assetIndex >= _assets.length) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final asset = _assets[assetIndex];
                final id = 'asset_${asset.id}';
                final selected = _isSelected(id);
                final order = _selectionOrder[id];
                return _AssetThumb(
                  asset: asset,
                  selected: selected,
                  order: order,
                  onTap: () => _toggleAsset(asset),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({
    required this.asset,
    required this.selected,
    required this.onTap,
    this.order,
  });

  final AssetEntity asset;
  final bool selected;
  final int? order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(const ThumbnailSize(300, 300)),
            builder: (context, snap) {
              final data = snap.data;
              if (data == null) {
                return ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                );
              }
              return Image.memory(
                data,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              );
            },
          ),
          if (asset.type == AssetType.video)
            const Positioned(
              left: 6,
              bottom: 6,
              child: Icon(Icons.play_circle_fill, color: Colors.white, size: 20),
            ),
          Positioned(
            top: 6,
            right: 6,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black45,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: selected
                  ? Text(
                      '${order ?? ''}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
