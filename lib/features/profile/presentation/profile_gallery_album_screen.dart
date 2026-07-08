import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/providers/app_providers.dart';
import '../../calendar/data/calendar_photo_sync_service.dart';
import '../../calendar/presentation/calendar_photo_pick_confirm_screen.dart';
import '../data/album_upload_coordinator.dart';
import 'album_upload_file_bytes.dart';
import 'read_picked_image_bytes.dart';
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
    this.isOwnGallery = false,
    this.excludeUploadedByUserId,
  });

  final int userId;
  final String albumId;
  final String title;
  final bool canManage;
  final bool isFamilyGallery;
  final bool isOwnGallery;
  final int? excludeUploadedByUserId;

  bool get isCustomAlbum => albumId.startsWith('custom:');

  int? get customAlbumPk {
    if (!isCustomAlbum) return null;
    return int.tryParse(albumId.substring(7));
  }

  @override
  ConsumerState<ProfileGalleryAlbumScreen> createState() =>
      _ProfileGalleryAlbumScreenState();
}

class _ProfileGalleryAlbumScreenState
    extends ConsumerState<ProfileGalleryAlbumScreen> {
  final List<Map<String, dynamic>> _photos = [];
  final TextEditingController _searchController = TextEditingController();
  final Set<int> _selectedPhotoIds = {};
  bool _loading = true;
  bool _loadingMore = false;
  bool _addingPhotos = false;
  bool _preparingUpload = false;
  bool _selectionMode = false;
  bool _searchMode = false;
  String? _error;
  String _query = '';
  int? _personUserId;
  bool _personFilterUnidentified = false;
  int _unidentifiedCount = 0;
  List<Map<String, dynamic>> _searchPeople = [];
  int _offset = 0;
  int _total = 0;
  int _uploadDone = 0;
  int _uploadFailed = 0;
  int _uploadTotal = 0;
  Timer? _uploadPollTimer;
  bool _uploadPolling = false;
  CalendarPhotoSyncInfo? _calendarSyncInfo;
  bool _calendarSyncRunning = false;
  bool _bulkActionRunning = false;
  int? _currentUserId;
  static const _pageSize = 60;
  static const _maxUploadCount = 500;
  static const _galleryAddChunkSize = 50;
  static const _uploadPollInterval = Duration(seconds: 3);

  int? _photoUploaderId(Map<String, dynamic> photo) {
    final id = photo['uploaded_by_user_id'];
    return id is int ? id : int.tryParse('$id');
  }

  List<Map<String, dynamic>> _applyUploadOwnerFilter(
      List<Map<String, dynamic>> photos) {
    final excluded = widget.excludeUploadedByUserId;
    if (excluded == null) return photos;
    return photos.where((p) => _photoUploaderId(p) != excluded).toList();
  }

  @override
  void initState() {
    super.initState();
    final albumPk = widget.customAlbumPk;
    if (albumPk != null) {
      AlbumUploadCoordinator.instance.addListener(_onCoordinatorUpdate);
      AlbumUploadCoordinator.instance.setAlbumScreenVisible(albumPk, true);
    }
    _load(reset: true);
    unawaited(_loadCurrentUserId());
    if (widget.isCustomAlbum) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_initCalendarPhotoSync());
        _syncFromCoordinator();
      });
    }
  }

  @override
  void dispose() {
    final albumPk = widget.customAlbumPk;
    if (albumPk != null) {
      AlbumUploadCoordinator.instance.removeListener(_onCoordinatorUpdate);
      AlbumUploadCoordinator.instance.setAlbumScreenVisible(albumPk, false);
    }
    _uploadPollTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onCoordinatorUpdate() {
    if (!mounted) return;
    final albumPk = widget.customAlbumPk;
    if (albumPk == null) return;

    final coordinator = AlbumUploadCoordinator.instance;
    final session = coordinator.sessionForAlbum(albumPk);
    final pending = coordinator.takePendingPhotos(albumPk);
    for (final photo in pending) {
      _prependPhotoIfNew(photo);
    }

    if (session != null && session.active) {
      setState(() {
        _addingPhotos = true;
        _preparingUpload = false;
        _uploadTotal = session.total;
        _uploadDone = session.done;
        _uploadFailed = session.failed;
      });
      _ensureUploadPollTimer();
      return;
    }

    if (_addingPhotos) {
      if (session != null) {
        setState(() {
          _uploadDone = session.done;
          _uploadFailed = session.failed;
          _uploadTotal = session.total;
        });
      }
      _endUploadSession();
      coordinator.clearSession(albumPk);
      unawaited(_pollNewPhotosDuringUpload());
      _showUploadSummary();
    }
  }

  void _syncFromCoordinator() {
    final albumPk = widget.customAlbumPk;
    if (albumPk == null) return;
    final session = AlbumUploadCoordinator.instance.sessionForAlbum(albumPk);
    if (session == null || !session.active) return;
    _onCoordinatorUpdate();
  }

  void _ensureUploadPollTimer() {
    if (_uploadPollTimer != null) return;
    _uploadPollTimer = Timer.periodic(_uploadPollInterval, (_) {
      unawaited(_pollNewPhotosDuringUpload());
    });
  }

  void _startCoordinatorUpload({
    required int albumPk,
    required List<AlbumUploadPhoto> photos,
  }) {
    AlbumUploadCoordinator.instance.startUploadToCustomAlbum(
      repo: ref.read(familychatRepositoryProvider),
      userId: widget.userId,
      albumPk: albumPk,
      albumId: widget.albumId,
      title: widget.title,
      photos: photos,
    );
    _ensureUploadPollTimer();
    _syncFromCoordinator();
  }

  Future<void> _initCalendarPhotoSync() async {
    final pk = widget.customAlbumPk;
    if (pk == null || !widget.canManage) return;
    final service =
        CalendarPhotoSyncService(ref.read(familychatRepositoryProvider));
    final info = await service.fetchAlbumSyncInfo(pk);
    if (!mounted) return;
    setState(() => _calendarSyncInfo = info);
    if (info != null &&
        CalendarPhotoSyncService.isAndroidNative &&
        info.autoSyncPhotos &&
        info.syncActive) {
      await _runCalendarAndroidSync(silent: true);
    }
  }

  Future<void> _runCalendarAndroidSync({bool silent = false}) async {
    final pk = widget.customAlbumPk;
    final info = _calendarSyncInfo;
    if (pk == null || info == null || _calendarSyncRunning) return;
    setState(() => _calendarSyncRunning = true);
    try {
      final service =
          CalendarPhotoSyncService(ref.read(familychatRepositoryProvider));
      final uploaded = await service.syncAndroidCameraPhotos(
        userId: widget.userId,
        info: info,
      );
      final refreshed = await service.fetchAlbumSyncInfo(pk);
      if (!mounted) return;
      setState(() => _calendarSyncInfo = refreshed ?? info);
      if (uploaded > 0) {
        await _load(reset: true);
        if (!mounted) return;
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Добавлено фото: $uploaded')),
          );
        }
      } else if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Новых фото с камеры не найдено')),
        );
      }
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка синхронизации: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _calendarSyncRunning = false);
    }
  }

  Future<void> _uploadCalendarPhotosFromPhone() async {
    final pk = widget.customAlbumPk;
    final info = _calendarSyncInfo;
    if (pk == null || info == null) return;
    final service =
        CalendarPhotoSyncService(ref.read(familychatRepositoryProvider));
    final picked = await service.pickWebPhotosWithDateFilter(info);
    if (!mounted || picked.isEmpty) return;
    final selected =
        await Navigator.of(context).push<List<CalendarDevicePhoto>>(
      MaterialPageRoute(
        builder: (_) => CalendarPhotoPickConfirmScreen(
          info: info,
          photos: picked,
        ),
      ),
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    setState(() => _addingPhotos = true);
    try {
      final uploaded = await service.uploadDevicePhotos(
        userId: widget.userId,
        albumPk: pk,
        photos: selected,
        alreadySynced: info.syncedDeviceAssetIds,
      );
      final refreshed = await service.fetchAlbumSyncInfo(pk);
      if (!mounted) return;
      setState(() => _calendarSyncInfo = refreshed ?? info);
      if (uploaded > 0) {
        await _load(reset: true);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Загружено фото: $uploaded')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка загрузки: $e')),
      );
    } finally {
      if (mounted) setState(() => _addingPhotos = false);
    }
  }

  Widget _buildCalendarSyncBanner() {
    final info = _calendarSyncInfo;
    if (info == null || !widget.canManage) return const SizedBox.shrink();

    final isAndroid = CalendarPhotoSyncService.isAndroidNative;
    final showWebUpload = kIsWeb;
    final showAndroidSync = isAndroid && info.syncActive;

    if (!showWebUpload && !showAndroidSync) return const SizedBox.shrink();

    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                info.autoSyncPhotos && isAndroid
                    ? 'Альбом события: фото с камеры подтягиваются автоматически'
                    : 'Альбом события: можно добавить фото с телефона',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (showWebUpload)
              TextButton(
                onPressed: _addingPhotos || _calendarSyncRunning
                    ? null
                    : _uploadCalendarPhotosFromPhone,
                child: const Text('Загрузить'),
              ),
            if (showAndroidSync)
              TextButton(
                onPressed: _addingPhotos || _calendarSyncRunning
                    ? null
                    : () => _runCalendarAndroidSync(),
                child: _calendarSyncRunning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Синхронизировать'),
              ),
          ],
        ),
      ),
    );
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
              personUnidentified: _personFilterUnidentified,
            )
          : await repo.memberGalleryPhotos(
              widget.userId,
              widget.albumId,
              offset: _offset,
              limit: _pageSize,
              query: _query,
              personUserId: _personUserId,
              personUnidentified: _personFilterUnidentified,
            );
      if (!mounted) return;
      final rawBatch =
          (data['photos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      final batch = _applyUploadOwnerFilter(rawBatch);
      setState(() {
        _total = data['total'] is int
            ? data['total'] as int
            : int.tryParse('${data['total']}') ?? 0;
        if (rawBatch.isEmpty && widget.excludeUploadedByUserId != null) {
          _total = _photos.length;
        }
        _photos.addAll(batch);
        _offset += rawBatch.length;
        _searchPeople = (data['search_people'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        _unidentifiedCount = data['unidentified_count'] is int
            ? data['unidentified_count'] as int
            : int.tryParse('${data['unidentified_count']}') ?? 0;
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

  void _beginPreparingUpload() {
    setState(() {
      _addingPhotos = true;
      _preparingUpload = true;
      _uploadTotal = 0;
      _uploadDone = 0;
      _uploadFailed = 0;
    });
  }

  void _endPreparingIfIdle() {
    if (!mounted || !_preparingUpload) return;
    final albumPk = widget.customAlbumPk;
    if (albumPk != null &&
        AlbumUploadCoordinator.instance.isActiveForAlbum(albumPk)) {
      return;
    }
    if (_uploadTotal > 0) return;
    setState(() {
      _preparingUpload = false;
      _addingPhotos = false;
    });
  }

  void _beginUploadSession(int total) {
    setState(() {
      _addingPhotos = true;
      _preparingUpload = false;
      _uploadTotal = total;
      _uploadDone = 0;
      _uploadFailed = 0;
    });
    _ensureUploadPollTimer();
  }

  void _endUploadSession() {
    _uploadPollTimer?.cancel();
    _uploadPollTimer = null;
    if (!mounted) return;
    setState(() {
      _addingPhotos = false;
      _preparingUpload = false;
    });
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
    if (!mounted ||
        !_addingPhotos ||
        _uploadPolling ||
        _searchMode ||
        _query.isNotEmpty) return;
    _uploadPolling = true;
    try {
      final fetchLimit =
          math.min(math.max(_photos.length + _pageSize, _pageSize), 200);
      final repo = ref.read(familychatRepositoryProvider);
      final data = widget.isFamilyGallery
          ? await repo.familyGalleryPhotos(
              widget.albumId,
              offset: 0,
              limit: fetchLimit,
              query: _query,
              personUserId: _personUserId,
              personUnidentified: _personFilterUnidentified,
            )
          : await repo.memberGalleryPhotos(
              widget.userId,
              widget.albumId,
              offset: 0,
              limit: fetchLimit,
              query: _query,
              personUserId: _personUserId,
              personUnidentified: _personFilterUnidentified,
            );
      if (!mounted) return;
      final rawBatch =
          (data['photos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      final batch = _applyUploadOwnerFilter(rawBatch);
      final newTotal = data['total'] is int
          ? data['total'] as int
          : int.tryParse('${data['total']}') ?? _total;
      final existingIds = _currentPhotoIds;
      final fresh = batch.where((photo) {
        final id = _photoId(photo);
        return id != null && !existingIds.contains(id);
      }).toList();
      if (fresh.isEmpty && newTotal == _total) return;
      setState(() {
        if (fresh.isNotEmpty) {
          _photos.insertAll(0, fresh);
        }
        _offset += rawBatch.length;
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
    _beginPreparingUpload();
    try {
      final photos = <AlbumUploadPhoto>[];
      for (final picked in items) {
        final bytes = await readPickedImageBytes(picked);
        photos.add(
          AlbumUploadPhoto(
            bytes: bytes,
            filename: picked.name,
            contentType:
                picked.mimeType ?? _imageContentTypeForFilename(picked.name),
          ),
        );
      }
      if (photos.isEmpty) return;
      _startCoordinatorUpload(albumPk: albumPk, photos: photos);
    } finally {
      _endPreparingIfIdle();
    }
  }

  Future<void> _uploadPhoneFiles({
    required int albumPk,
    required List<PlatformFile> files,
  }) async {
    final items = _limitUploadSelection(files);
    if (items.isEmpty) return;
    _beginPreparingUpload();
    try {
      final photos = <AlbumUploadPhoto>[];
      for (final file in items) {
        final bytes = await readAlbumUploadFileBytes(file);
        if (bytes == null || bytes.isEmpty) continue;
        final ext = (file.extension ?? '').toLowerCase();
        final inferredContentType = switch (ext) {
          'png' => 'image/png',
          'webp' => 'image/webp',
          'heic' || 'heif' => 'image/heic',
          'gif' => 'image/gif',
          _ => 'image/jpeg',
        };
        photos.add(
          AlbumUploadPhoto(
            bytes: bytes,
            filename: file.name,
            contentType: inferredContentType,
          ),
        );
      }
      if (photos.isEmpty) return;
      _startCoordinatorUpload(albumPk: albumPk, photos: photos);
    } finally {
      _endPreparingIfIdle();
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
        final chunk =
            ids.sublist(i, math.min(i + _galleryAddChunkSize, ids.length));
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

  List<int> get _selectablePhotoIds =>
      _photos.map(_photoId).whereType<int>().toList();

  bool _photoIsOwnUpload(Map<String, dynamic> photo) {
    final myId = _currentUserId;
    if (myId == null) return false;
    final uploader = photo['uploaded_by_user_id'];
    final uid = uploader is int ? uploader : int.tryParse('$uploader');
    return uid == myId;
  }

  List<int> get _selectedOwnPhotoIds => _photos
      .where((photo) {
        final id = _photoId(photo);
        return id != null &&
            _selectedPhotoIds.contains(id) &&
            _photoIsOwnUpload(photo);
      })
      .map(_photoId)
      .whereType<int>()
      .toList();

  Future<void> _loadCurrentUserId() async {
    try {
      final status = await ref.read(familychatRepositoryProvider).status();
      final userId = status['user_id'];
      if (!mounted) return;
      setState(() {
        _currentUserId = userId is int ? userId : int.tryParse('$userId');
      });
    } catch (_) {}
  }

  bool get _allPhotosSelected {
    final ids = _selectablePhotoIds;
    return ids.isNotEmpty && ids.every(_selectedPhotoIds.contains);
  }

  void _toggleSelectAllPhotos() {
    final ids = _selectablePhotoIds;
    setState(() {
      if (_allPhotosSelected) {
        _selectedPhotoIds.removeAll(ids);
      } else {
        _selectedPhotoIds.addAll(ids);
      }
    });
  }

  void _togglePhotoSelection(Map<String, dynamic> photo) {
    final id = photo['id'] is int
        ? photo['id'] as int
        : int.tryParse('${photo['id']}');
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
    final id = photo['id'] is int
        ? photo['id'] as int
        : int.tryParse('${photo['id']}');
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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (tag == null || tag.isEmpty || !mounted) return;
    try {
      final res =
          await ref.read(familychatRepositoryProvider).bulkTagGalleryPhotos(
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<void> _applySearch() async {
    setState(() {
      _query = _searchController.text.trim();
      _personUserId = null;
      _personFilterUnidentified = false;
    });
    await _load(reset: true);
  }

  Future<void> _editAlbum() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    final albums = await ref
        .read(familychatRepositoryProvider)
        .memberGalleryAlbums(widget.userId);
    Map<String, dynamic>? album;
    for (final a in (albums['albums'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()) {
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

  Future<void> _deleteSelectedPhotos() async {
    final ids = _selectedOwnPhotoIds;
    if (ids.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Можно удалить только свои фото')),
      );
      return;
    }

    final skipped = _selectedPhotoIds.length - ids.length;
    final count = ids.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить фото?'),
        content: Text(
          skipped > 0
              ? 'Будет удалено $count ${_photoWord(count)} совсем — из всех альбомов и чата. '
                  'Ещё $skipped ${_photoWord(skipped)} не ваши и не будут удалены.'
              : count == 1
                  ? 'Фото будет удалено совсем — из всех альбомов и чата.'
                  : 'Выбранные фото ($count) будут удалены совсем — из всех альбомов и чата.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final res =
          await ref.read(familychatRepositoryProvider).bulkDeleteGalleryPhotos(
                widget.userId,
                attachmentIds: ids,
              );
      if (!mounted) return;
      final deleted = res['deleted'];
      final notOwner = res['skipped_not_owner'];
      final message = deleted == ids.length
          ? 'Удалено: $deleted'
          : 'Удалено: ${deleted ?? 0}, пропущено: ${notOwner ?? 0}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      setState(() {
        _selectedPhotoIds.clear();
        _selectionMode = false;
      });
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  String _photoWord(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return 'фото';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'фото';
    return 'фото';
  }

  List<Map<String, dynamic>> get _selectedPhotos => _photos.where((photo) {
        final id = _photoId(photo);
        return id != null && _selectedPhotoIds.contains(id);
      }).toList();

  Future<List<XFile>> _loadSelectedPhotoFiles() async {
    final repo = ref.read(familychatRepositoryProvider);
    final files = <XFile>[];
    for (final photo in _selectedPhotos) {
      final threadId = photo['thread_id'];
      final attachmentId = _photoId(photo);
      if (threadId is! int || attachmentId == null) continue;
      final bytes = await repo.fetchChatAttachmentBytes(threadId, attachmentId);
      final rawName = photo['filename']?.toString().trim() ?? '';
      final name = rawName.isNotEmpty ? rawName : 'photo_$attachmentId.jpg';
      files.add(XFile.fromData(bytes, name: name));
    }
    return files;
  }

  Future<void> _downloadSelectedPhotos() async {
    final selected = _selectedPhotos;
    if (selected.isEmpty || _bulkActionRunning) return;
    setState(() => _bulkActionRunning = true);
    try {
      final files = await _loadSelectedPhotoFiles();
      if (files.isEmpty) {
        throw StateError('Не удалось загрузить файлы');
      }
      // ignore: deprecated_member_use
      await Share.shareXFiles(files);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Готово: ${files.length} фото')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка скачивания: $e')),
      );
    } finally {
      if (mounted) setState(() => _bulkActionRunning = false);
    }
  }

  Future<void> _shareSelectedPhotos() async {
    final selected = _selectedPhotos;
    if (selected.isEmpty || _bulkActionRunning) return;
    setState(() => _bulkActionRunning = true);
    try {
      final files = await _loadSelectedPhotoFiles();
      if (files.isEmpty) {
        throw StateError('Не удалось подготовить файлы');
      }
      // ignore: deprecated_member_use
      await Share.shareXFiles(files);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    } finally {
      if (mounted) setState(() => _bulkActionRunning = false);
    }
  }

  Future<void> _deduplicateAlbum() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить дубликаты?'),
        content: const Text(
          'В альбоме будут найдены одинаковые фото (по содержимому). '
          'Останется самое раннее, остальные ваши копии будут удалены совсем.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить дубликаты')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final res =
          await ref.read(familychatRepositoryProvider).deduplicateGalleryAlbum(
                widget.userId,
                widget.albumId,
              );
      if (!mounted) return;
      final deleted = res['deleted'] ?? 0;
      final skipped = res['skipped_not_owner'] ?? 0;
      final groups = res['duplicate_groups'] ?? 0;
      final text = deleted == 0
          ? (groups == 0
              ? 'Дубликатов не найдено'
              : 'Удалено: 0 (чужие копии не трогаем)')
          : 'Удалено дубликатов: $deleted${skipped > 0 ? ', пропущено чужих: $skipped' : ''}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<void> _deleteAlbum() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить альбом?'),
        content: Text(
            'Альбом «${widget.title}» будет удалён. Фото останутся в галерее.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(familychatRepositoryProvider)
          .deleteCustomGalleryAlbum(widget.userId, pk);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
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
    if (source == ImageSource.gallery) {
      await _uploadFromPhoneGallery();
      return;
    }
    _beginPreparingUpload();
    await Future<void>.delayed(Duration.zero);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        requestFullMetadata: true,
      );
      if (!mounted || picked == null) return;
      await _uploadDeviceImages(albumPk: pk, pickedItems: [picked]);
    } finally {
      _endPreparingIfIdle();
    }
  }

  Future<void> _uploadFromPhoneGallery() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    _beginPreparingUpload();
    await Future<void>.delayed(Duration.zero);
    try {
      final picker = ImagePicker();
      final pickedMany = await picker.pickMultiImage(
        requestFullMetadata: true,
      );
      if (!mounted) return;
      if (pickedMany.isNotEmpty) {
        await _uploadDeviceImages(albumPk: pk, pickedItems: pickedMany);
        return;
      }
      final pickedOne = await picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: true,
      );
      if (!mounted || pickedOne == null) return;
      await _uploadDeviceImages(albumPk: pk, pickedItems: [pickedOne]);
    } finally {
      _endPreparingIfIdle();
    }
  }

  Future<void> _uploadFromPhoneFiles() async {
    final pk = widget.customAlbumPk;
    if (pk == null) return;
    _beginPreparingUpload();
    await Future<void>.delayed(Duration.zero);
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: kIsWeb,
        type: FileType.image,
      );
      if (!mounted) return;
      if (picked == null || picked.files.isEmpty) return;
      await _uploadPhoneFiles(albumPk: pk, files: picked.files);
    } finally {
      _endPreparingIfIdle();
    }
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

  Widget _buildPreparingOverlay() {
    if (!_preparingUpload) return const SizedBox.shrink();
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.35),
          child: Center(
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'Обработка выбранных фото...',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Это может занять некоторое время',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canManageCustom = widget.canManage && widget.isCustomAlbum;

    return Stack(
      children: [
        Scaffold(
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
                        _preparingUpload
                            ? 'Подготовка...'
                            : '$_uploadDone/$_uploadTotal',
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
                        _personFilterUnidentified = false;
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
                icon: Icon(
                    _selectionMode ? Icons.close : Icons.checklist_outlined),
              ),
              if (_selectionMode)
                TextButton(
                  onPressed: _selectablePhotoIds.isEmpty
                      ? null
                      : _toggleSelectAllPhotos,
                  child: Text(_allPhotosSelected ? 'Снять все' : 'Выбрать все'),
                ),
              if (_selectionMode)
                PopupMenuButton<String>(
                  enabled: _selectedPhotoIds.isNotEmpty && !_bulkActionRunning,
                  tooltip: 'Действия',
                  onSelected: (value) {
                    switch (value) {
                      case 'download':
                        _downloadSelectedPhotos();
                      case 'share':
                        _shareSelectedPhotos();
                      case 'tag':
                        _showBulkTagDialog();
                      case 'delete':
                        _deleteSelectedPhotos();
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                        value: 'download', child: Text('Скачать')),
                    const PopupMenuItem(
                        value: 'share', child: Text('Поделиться')),
                    const PopupMenuItem(
                        value: 'tag', child: Text('Добавить тег')),
                    if (widget.isOwnGallery)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Удалить',
                            style: TextStyle(color: Colors.red)),
                      ),
                  ],
                  icon: _bulkActionRunning
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const Icon(Icons.more_vert),
                ),
              if (!_selectionMode && (canManageCustom || widget.isOwnGallery))
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'dedupe':
                        _deduplicateAlbum();
                      case 'edit':
                        _editAlbum();
                      case 'delete':
                        _deleteAlbum();
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (widget.isOwnGallery)
                      const PopupMenuItem(
                          value: 'dedupe', child: Text('Удалить дубликаты')),
                    if (canManageCustom) ...[
                      const PopupMenuItem(
                          value: 'edit', child: Text('Редактировать')),
                      const PopupMenuItem(
                          value: 'delete', child: Text('Удалить альбом')),
                    ],
                  ],
                ),
            ],
          ),
          floatingActionButton: _selectionMode
              ? FloatingActionButton.extended(
                  onPressed:
                      _selectedPhotoIds.isEmpty ? null : _showBulkTagDialog,
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
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.add_photo_alternate_outlined),
                    )
                  : null,
          body: Column(
            children: [
              _buildCalendarSyncBanner(),
              Expanded(
                child: _loading
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
                                          Text(
                                            _preparingUpload
                                                ? 'Обработка выбранных фото...'
                                                : 'Загрузка $_uploadDone из $_uploadTotal...',
                                          ),
                                          if (_preparingUpload) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              'Это может занять некоторое время',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
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
                                                onPressed: _addingPhotos
                                                    ? null
                                                    : _showAddPhotosSheet,
                                                icon: const Icon(Icons
                                                    .add_photo_alternate_outlined),
                                                label:
                                                    const Text('Добавить фото'),
                                              ),
                                            ],
                                          )
                                        : const Text('Нет фото'),
                              )
                            : Column(
                                children: [
                                  if (_searchPeople.isNotEmpty || _total > 0)
                                    SizedBox(
                                      height: 46,
                                      child: ListView(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8),
                                        scrollDirection: Axis.horizontal,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4),
                                            child: ChoiceChip(
                                              label: const Text('Все люди'),
                                              selected: _personUserId == null &&
                                                  !_personFilterUnidentified,
                                              showCheckmark: false,
                                              onSelected: (_) async {
                                                setState(() {
                                                  _personUserId = null;
                                                  _personFilterUnidentified =
                                                      false;
                                                });
                                                await _load(reset: true);
                                              },
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4),
                                            child: ChoiceChip(
                                              showCheckmark: false,
                                              visualDensity:
                                                  const VisualDensity(
                                                      horizontal: -4,
                                                      vertical: -4),
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              label: Tooltip(
                                                message: _unidentifiedCount > 0
                                                    ? 'Не определены ($_unidentifiedCount)'
                                                    : 'Не определены',
                                                child: SizedBox.square(
                                                  dimension: 36,
                                                  child: CircleAvatar(
                                                    radius: 18,
                                                    backgroundColor: Theme.of(
                                                            context)
                                                        .colorScheme
                                                        .surfaceContainerHighest,
                                                    child: Icon(
                                                      Icons.face_retouching_off,
                                                      size: 20,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              selected:
                                                  _personFilterUnidentified,
                                              onSelected: (_) async {
                                                setState(() {
                                                  _personFilterUnidentified =
                                                      true;
                                                  _personUserId = null;
                                                });
                                                await _load(reset: true);
                                              },
                                            ),
                                          ),
                                          for (final person in _searchPeople)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 4),
                                              child: ChoiceChip(
                                                showCheckmark: false,
                                                visualDensity:
                                                    const VisualDensity(
                                                        horizontal: -4,
                                                        vertical: -4),
                                                materialTapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                                label: Tooltip(
                                                  message: person['name']
                                                          ?.toString() ??
                                                      '',
                                                  child: SizedBox.square(
                                                    dimension: 36,
                                                    child: ChatAvatar(
                                                      name: person['name']
                                                              ?.toString() ??
                                                          '',
                                                      avatarUrl:
                                                          person['avatar_url']
                                                              ?.toString(),
                                                      radius: 18,
                                                    ),
                                                  ),
                                                ),
                                                selected: _personUserId ==
                                                    person['user_id'],
                                                onSelected: (_) async {
                                                  setState(() {
                                                    _personUserId =
                                                        person['user_id']
                                                            as int?;
                                                    _personFilterUnidentified =
                                                        false;
                                                  });
                                                  await _load(reset: true);
                                                },
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  Expanded(
                                    child: NotificationListener<
                                        ScrollNotification>(
                                      onNotification: (n) {
                                        if (n.metrics.pixels >=
                                                n.metrics.maxScrollExtent -
                                                    200 &&
                                            !_loadingMore &&
                                            _photos.length < _total) {
                                          _load(reset: false);
                                        }
                                        return false;
                                      },
                                      child: GridView.builder(
                                        padding: const EdgeInsets.all(8),
                                        gridDelegate:
                                            const SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 3,
                                          crossAxisSpacing: 4,
                                          mainAxisSpacing: 4,
                                        ),
                                        itemCount: _photos.length +
                                            (_loadingMore ? 1 : 0),
                                        itemBuilder: (_, i) {
                                          if (i >= _photos.length) {
                                            return const Center(
                                              child: Padding(
                                                padding: EdgeInsets.all(12),
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2),
                                              ),
                                            );
                                          }
                                          final photo = _photos[i];
                                          final threadId = photo['thread_id'];
                                          if (threadId is! int) {
                                            return const ColoredBox(
                                                color: Color(0x22000000));
                                          }
                                          final id = photo['id'] is int
                                              ? photo['id'] as int
                                              : int.tryParse('${photo['id']}');
                                          final selected = id != null &&
                                              _selectedPhotoIds.contains(id);
                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: _selectionMode
                                                ? () =>
                                                    _togglePhotoSelection(photo)
                                                : () =>
                                                    _openPhotoViewer(photo, i),
                                            onLongPress: _selectionMode
                                                ? () =>
                                                    _togglePhotoSelection(photo)
                                                : () =>
                                                    _enterSelectionWithPhoto(
                                                        photo),
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
                                                    alignment:
                                                        Alignment.topRight,
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              6),
                                                      child: Icon(
                                                        selected
                                                            ? Icons.check_circle
                                                            : Icons
                                                                .radio_button_unchecked,
                                                        color: selected
                                                            ? Colors
                                                                .lightGreenAccent
                                                            : Colors.white70,
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
              ),
            ],
          ),
        ),
        _buildPreparingOverlay(),
      ],
    );
  }
}
