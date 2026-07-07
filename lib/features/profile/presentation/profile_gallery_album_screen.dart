import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers/app_providers.dart';
import 'album_upload_file_bytes.dart';
import 'custom_album_dialog.dart';
import 'gallery_photo_viewer_screen.dart';
import 'pick_gallery_photos_sheet.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import 'widgets/chat_avatar.dart';

class ProfileGalleryAlbumScreen extends ConsumerStatefulWidget {
  const ProfileGalleryAlbumScreen({
    super.key,
    required this.userId,
    required this.albumId,
    required this.title,
    this.canManage = false,
    this.isFamilyGallery = false,
  });

  final int userId;
  final String albumId;
  final String title;
  final bool canManage;
  final bool isFamilyGallery;

  bool get isCustomAlbum => albumId.startsWith('custom:');

  int? get customAlbumPk {
    if (!isCustomAlbum) return null;
    return int.tryParse(albumId.substring(7));
  }

  @override
  ConsumerState<ProfileGalleryAlbumScreen> createState() => _ProfileGalleryAlbumScreenState();
}

class _ProfileGalleryAlbumScreenState extends ConsumerState<ProfileGalleryAlbumScreen> {
  final List<Map<String, dynamic>> _photos = [];
  final TextEditingController _searchController = TextEditingController();
  final Set<int> _selectedPhotoIds = {};
  bool _loading = true;
  bool _loadingMore = false;
  bool _addingPhotos = false;
  bool _selectionMode = false;
  bool _searchMode = false;
  String? _error;
  String _query = '';
  int? _personUserId;
  List<Map<String, dynamic>> _searchPeople = [];
  int _offset = 0;
  int _total = 0;
  int _uploadDone = 0;
  int _uploadFailed = 0;
  int _uploadTotal = 0;
  Timer? _uploadPollTimer;
  bool _uploadPolling = false;
  static const _pageSize = 60;
  static const _maxUploadCount = 500;
  static const _galleryAddChunkSize = 50;
  static const _uploadPollInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _uploadPollTimer?.cancel();
    _searchController.dispose();
    super.dispose();
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
      final repo = ref.read(familychatRepositoryProvider);
      final data = widget.isFamilyGallery
          ? await repo.familyGalleryPhotos(
              widget.albumId,
              offset: _offset,
              limit: _pageSize,
              query: _query,
              personUserId: _personUserId,
            )
          : await repo.memberGalleryPhotos(
              widget.userId,
              widget.albumId,
              offset: _offset,
              limit: _pageSize,
              query: _query,
              personUserId: _personUserId,
            );
      if (!mounted) return;
      final batch = (data['photos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _total = data['total'] is int ? data['total'] as int : int.tryParse('${data['total']}') ?? 0;
        _photos.addAll(batch);
        _offset += batch.length;
        _searchPeople =
            (data['search_people'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
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

  Set<int> get _currentPhotoIds {
    return _photos
        .map((p) => p['id'])
        .map((id) => id is int ? id : int.tryParse('$id'))
        .whereType<int>()
        .toSet();
  }

  int? _photoId(Map<String, dynamic> photo) {
    final id = photo['id'];
    return id is int ? id : int.tryParse('$id');
  }

  void _beginUploadSession(int total) {
    setState(() {
      _addingPhotos = true;
      _uploadTotal = total;
      _uploadDone = 0;
      _uploadFailed = 0;
    });
    _uploadPollTimer?.cancel();
    _uploadPollTimer = Timer.periodic(_uploadPollInterval, (_) {
      unawaited(_pollNewPhotosDuringUpload());
    });
  }

  void _endUploadSession() {
    _uploadPollTimer?.cancel();
    _uploadPollTimer = null;
    if (!mounted) return;
    setState(() => _addingPhotos = false);
  }

  void _onUploadProgress({required bool success}) {
    if (!mounted) return;
    setState(() {
      if (success) {
        _uploadDone++;
      } else {
        _uploadFailed++;
      }
    });
  }

  void _prependPhotoIfNew(Map<String, dynamic> photo) {
    final id = _photoId(photo);
    if (id == null || _currentPhotoIds.contains(id)) return;
    setState(() {
      _photos.insert(0, photo);
      _offset++;
      _total++;
    });
  }

  Future<void> _pollNewPhotosDuringUpload() async {
    if (!mounted || !_addingPhotos || _uploadPolling || _searchMode || _query.isNotEmpty) return;
    _uploadPolling = true;
    try {
      final fetchLimit = math.min(math.max(_photos.length + _pageSize, _pageSize), 200);
      final repo = ref.read(familychatRepositoryProvider);
      final data = widget.isFamilyGallery
          ? await repo.familyGalleryPhotos(
              widget.albumId,
              offset: 0,
              limit: fetchLimit,
              query: _query,
              personUserId: _personUserId,
            )
          : await repo.memberGalleryPhotos(
              widget.userId,
              widget.albumId,
              offset: 0,
              limit: fetchLimit,
              query: _query,
              personUserId: _personUserId,
            );
      if (!mounted) return;
      final batch = (data['photos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      final newTotal =
          data['total'] is int ? data['total'] as int : int.tryParse('${data['total']}') ?? _total;
      final existingIds = _currentPhotoIds;
      final fresh = batch
          .where((photo) {
            final id = _photoId(photo);
            return id != null && !existingIds.contains(id);
          })
          .toList();
      if (fresh.isEmpty && newTotal == _total) return;
      setState(() {
        if (fresh.isNotEmpty) {
          _photos.insertAll(0, fresh);
          _offset += fresh.length;
        }
        _total = newTotal;
      });
    } catch (_) {
      // Ignore polling errors while upload continues.
    } finally {
      _uploadPolling = false;
    }
  }

  void _showUploadSummary() {
    if (!mounted) return;
    final message = _uploadFailed == 0
        ? 'Загружено фото: $_uploadDone'
        : 'Загружено: $_uploadDone, ошибок: $_uploadFailed';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  List<T> _limitUploadSelection<T>(List<T> items) {
    if (items.length <= _maxUploadCount) return items;
    if (!mounted) return items.take(_maxUploadCount).toList();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Можно загрузить не более $_maxUploadCount фото. Выбрано первые $_maxUploadCount.',
        ),
      ),
    );
    return items.take(_maxUploadCount).toList();
  }

  Future<void> _uploadDeviceImages({
    required int albumPk,
    required List<XFile> pickedItems,
  }) async {
    final items = _limitUploadSelection(pickedItems);
    if (items.isEmpty) return;
    _beginUploadSession(items.length);
    final repo = ref.read(familychatRepositoryProvider);
    try {
      for (final picked in items) {
        try {
          final bytes = await picked.readAsBytes();
          final contentType = picked.mimeType ?? _imageContentTypeForFilename(picked.name);
          final uploaded = await repo.uploadPhotoToCustomAlbum(
            widget.userId,
            albumPk,
            bytes: bytes,
            filename: picked.name,
            contentType: contentType,
          );
          _prependPhotoIfNew(uploaded);
          _onUploadProgress(success: true);
          await _pollNewPhotosDuringUpload();
        } catch (_) {
          _onUploadProgress(success: false);
        }
      }
      await _pollNewPhotosDuringUpload();
      _showUploadSummary();
    } finally {
      _endUploadSession();
    }
  }

  Future<void> _uploadPhoneFiles({
    required int albumPk,
    required List<PlatformFile> files,
  }) async {
    final items = _limitUploadSelection(files);
    if (items.isEmpty) return;
    _beginUploadSession(items.length);
    final repo = ref.read(familychatRepositoryProvider);
    try {
      for (final file in items) {
        try {
          final bytes = await readAlbumUploadFileBytes(file);
          if (bytes == null || bytes.isEmpty) {
            _onUploadProgress(success: false);
            continue;
          }
          final ext = (file.extension ?? '').toLowerCase();
          final inferredContentType = switch (ext) {
            'png' => 'image/png',
            'webp' => 'image/webp',
            'heic' || 'heif' => 'image/heic',
            'gif' => 'image/gif',
            _ => 'image/jpeg',
          };
          final uploaded = await repo.uploadPhotoToCustomAlbum(
            widget.userId,
            albumPk,
            bytes: bytes,
            filename: file.name,
            contentType: inferredContentType,
          );
          _prependPhotoIfNew(uploaded);
          _onUploadProgress(success: true);
          await _pollNewPhotosDuringUpload();
        } catch (_) {
          _onUploadProgress(success: false);
        }
      }
      await _pollNewPhotosDuringUpload();
      _showUploadSummary();
    } finally {
      _endUploadSession();
    }
  }

  Future<void> _addGalleryPhotosInChunks({
    required int albumPk,
    required List<int> attachmentIds,
  }) async {
    final ids = _limitUploadSelection(attachmentIds);
    if (ids.isEmpty) return;
    _beginUploadSession(ids.length);
    final repo = ref.read(familychatRepositoryProvider);
    try {
      for (var i = 0; i < ids.length; i += _galleryAddChunkSize) {
        final chunk = ids.sublist(i, math.min(i + _galleryAddChunkSize, ids.length));
        try {
          await repo.addPhotosToCustomAlbum(widget.userId, albumPk, chunk);
          for (var j = 0; j < chunk.length; j++) {
            _onUploadProgress(success: true);
          }
          await _pollNewPhotosDuringUpload();
        } catch (_) {
          for (var j = 0; j < chunk.length; j++) {
            _onUploadProgress(success: false);
          }
        }
      }
      await _pollNewPhotosDuringUpload();
      _showUploadSummary();
    } finally {
      _endUploadSession();
    }
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedPhotoIds.clear();
    });
  }

  void _togglePhotoSelection(Map<String, dynamic> photo) {
    final id = photo['id'] is int ? photo['id'] as int : int.tryParse('${photo['id']}');
    if (id == null) return;
    setState(() {
      if (_selectedPhotoIds.contains(id)) {
        _selectedPhotoIds.remove(id);
      } else {
        _selectedPhotoIds.add(id);
      }
    });
  }

  void _enterSelectionWithPhoto(Map<String, dynamic> photo) {
    final id = photo['id'] is int ? photo['id'] as int : int.tryParse('${photo['id']}');
    if (id == null) return;
    setState(() {
      _selectionMode = true;
      _selectedPhotoIds.add(id);
    });
  }

  Future<void> _openPhotoViewer(Map<String, dynamic> photo, int index) async {
    final status = await ref.read(familychatRepositoryProvider).status();
    final currentUserId = status['user_id'];
    if (!context.mounted || currentUserId is! int) return;
    await GalleryPhotoViewerScreen.open(
      context,
      profileUserId: widget.userId,
      photo: photo,
      currentUserId: currentUserId,
      photos: _photos,
      initialIndex: index,
      onChanged: () => _load(reset: true),
    );
  }

  Future<void> _showBulkTagDialog() async {
    if (_selectedPhotoIds.isEmpty) return;
    final controller = TextEditingController();
    final tag = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить тег'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Тег',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (tag == null || tag.isEmpty || !mounted) return;
    try {
      final res = await ref.read(familychatRepositoryProvider).bulkTagGalleryPhotos(
            widget.userId,
            widget.albumId,
            attachmentIds: _selectedPhotoIds.toList(),
            tag: tag,
          );
      if (!mounted) return;
      final created = res['created'];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Тег добавлен: ${created ?? 0} фото')),
      );
      setState(() {
        _selectedPhotoIds.clear();
        _selectionMode = false;
      });
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<void> _applySearch() async {
    setState(() {
      _query = _searchController.text.trim();
      _personUserId = null;
    });
    await _load(reset: true);
  }

  Future<void> _editAlbum() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    final albums = await ref.read(familychatRepositoryProvider).memberGalleryAlbums(widget.userId);
    Map<String, dynamic>? album;
    for (final a in (albums['albums'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>()) {
      if (a['id']?.toString() == widget.albumId) {
        album = a;
        break;
      }
    }
    if (album == null || !mounted) return;
    final accessIds = (album['access_user_ids'] as List<dynamic>? ?? [])
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
    final updated = await CustomAlbumDialog.show(
      context,
      userId: widget.userId,
      albumPk: pk,
      initialTitle: album['title']?.toString() ?? widget.title,
      initialAccessMode: album['access_mode']?.toString() ?? 'all',
      initialAccessUserIds: accessIds,
    );
    if (updated == true && mounted) {
      await _load(reset: true);
    }
  }

  Future<void> _deleteAlbum() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить альбом?'),
        content: Text('Альбом «${widget.title}» будет удалён. Фото останутся в галерее.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(familychatRepositoryProvider).deleteCustomGalleryAlbum(widget.userId, pk);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<void> _pickFromGallery() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    final ids = await PickGalleryPhotosSheet.show(
      context,
      userId: widget.userId,
      excludeAttachmentIds: _currentPhotoIds,
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    await _addGalleryPhotosInChunks(albumPk: pk, attachmentIds: ids);
  }

  String? _imageContentTypeForFilename(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  Future<void> _uploadFromDevice(ImageSource source) async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    final picker = ImagePicker();
    final pickedItems = source == ImageSource.gallery
        ? await picker.pickMultiImage(requestFullMetadata: true)
        : [
            if (await picker.pickImage(
              source: source,
              requestFullMetadata: true,
            )
                case final xfile?)
              xfile,
          ];
    if (pickedItems.isEmpty || !mounted) return;
    await _uploadDeviceImages(albumPk: pk, pickedItems: pickedItems);
  }

  Future<void> _uploadFromPhoneFiles() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: kIsWeb,
      type: FileType.image,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    await _uploadPhoneFiles(albumPk: pk, files: picked.files);
  }

  Future<void> _showAddPhotosSheet() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Из галереи'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Галерея телефона'),
              onTap: () => Navigator.pop(ctx, 'phone'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Файлы с телефона'),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Камера'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'gallery':
        await _pickFromGallery();
      case 'phone':
        await _uploadFromDevice(ImageSource.gallery);
      case 'files':
        await _uploadFromPhoneFiles();
      case 'camera':
        await _uploadFromDevice(ImageSource.camera);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManageCustom = widget.canManage && widget.isCustomAlbum;

    return Scaffold(
      appBar: AppBar(
        title: _searchMode
            ? TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Поиск по тегам',
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _applySearch(),
              )
            : Text(widget.title),
        actions: [
          if (_addingPhotos)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_uploadDone/$_uploadTotal',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ),
            ),
          if (!_selectionMode && !_addingPhotos)
            IconButton(
              tooltip: 'Поиск',
              onPressed: () async {
                if (_searchMode) {
                  setState(() {
                    _searchMode = false;
                    _query = '';
                    _personUserId = null;
                    _searchController.clear();
                  });
                  await _load(reset: true);
                } else {
                  setState(() => _searchMode = true);
                }
              },
              icon: Icon(_searchMode ? Icons.close : Icons.search),
            ),
          IconButton(
            tooltip: _selectionMode ? 'Отменить выбор' : 'Выбрать',
            onPressed: _toggleSelectionMode,
            icon: Icon(_selectionMode ? Icons.close : Icons.checklist_outlined),
          ),
          if (canManageCustom)
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    _editAlbum();
                  case 'delete':
                    _deleteAlbum();
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(value: 'edit', child: Text('Редактировать')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить')),
              ],
            ),
        ],
      ),
      floatingActionButton: _selectionMode
          ? FloatingActionButton.extended(
              onPressed: _selectedPhotoIds.isEmpty ? null : _showBulkTagDialog,
              icon: const Icon(Icons.sell_outlined),
              label: Text('Тег (${_selectedPhotoIds.length})'),
            )
          : canManageCustom
              ? FloatingActionButton(
                  onPressed: _addingPhotos ? null : _showAddPhotosSheet,
                  child: _addingPhotos
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined),
                )
              : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => _load(reset: true),
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
                )
              : _photos.isEmpty
                  ? Center(
                      child: _addingPhotos
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text('Загрузка $_uploadDone из $_uploadTotal...'),
                                if (_uploadFailed > 0) ...[
                                  const SizedBox(height: 8),
                                  Text('Ошибок: $_uploadFailed'),
                                ],
                              ],
                            )
                          : canManageCustom
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Альбом пуст'),
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: _addingPhotos ? null : _showAddPhotosSheet,
                                  icon: const Icon(Icons.add_photo_alternate_outlined),
                                  label: const Text('Добавить фото'),
                                ),
                              ],
                            )
                          : const Text('Нет фото'),
                    )
                  : Column(
                      children: [
                        if (_searchPeople.isNotEmpty)
                          SizedBox(
                            height: 46,
                            child: ListView(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              scrollDirection: Axis.horizontal,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: ChoiceChip(
                                    label: const Text('Все люди'),
                                    selected: _personUserId == null,
                                    showCheckmark: false,
                                    onSelected: (_) async {
                                      setState(() => _personUserId = null);
                                      await _load(reset: true);
                                    },
                                  ),
                                ),
                                for (final person in _searchPeople)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: ChoiceChip(
                                      showCheckmark: false,
                                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      label: Tooltip(
                                        message: person['name']?.toString() ?? '',
                                        child: SizedBox.square(
                                          dimension: 36,
                                          child: ChatAvatar(
                                            name: person['name']?.toString() ?? '',
                                            avatarUrl: person['avatar_url']?.toString(),
                                            radius: 18,
                                          ),
                                        ),
                                      ),
                                      selected: _personUserId == person['user_id'],
                                      onSelected: (_) async {
                                        setState(() => _personUserId = person['user_id'] as int?);
                                        await _load(reset: true);
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200 &&
                            !_loadingMore &&
                            _photos.length < _total) {
                          _load(reset: false);
                        }
                        return false;
                      },
                      child: GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: _photos.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i >= _photos.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            );
                          }
                          final photo = _photos[i];
                          final threadId = photo['thread_id'];
                          if (threadId is! int) {
                            return const ColoredBox(color: Color(0x22000000));
                          }
                          final id = photo['id'] is int ? photo['id'] as int : int.tryParse('${photo['id']}');
                          final selected = id != null && _selectedPhotoIds.contains(id);
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _selectionMode
                                ? () => _togglePhotoSelection(photo)
                                : () => _openPhotoViewer(photo, i),
                            onLongPress: _selectionMode
                                ? () => _togglePhotoSelection(photo)
                                : () => _enterSelectionWithPhoto(photo),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ChatNetworkImage(
                                  threadId: threadId,
                                  attachment: photo,
                                  fit: BoxFit.cover,
                                ),
                                if (_selectionMode)
                                  Align(
                                    alignment: Alignment.topRight,
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Icon(
                                        selected
                                            ? Icons.check_circle
                                            : Icons.radio_button_unchecked,
                                        color: selected ? Colors.lightGreenAccent : Colors.white70,
                                      ),
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
                    ),
    );
  }
}
