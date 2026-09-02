import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/media/gallery_photo_local_state.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_models.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_sheet.dart';
import '../../gallery/presentation/gallery_media_thumbnail.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';
import 'scrapbook/utils/milestone_gallery_viewer.dart';

/// Деталка вехи в стиле Dairy (просмотр + правки для опекунов).
class ChildMilestoneDetailScreen extends ConsumerStatefulWidget {
  const ChildMilestoneDetailScreen({
    super.key,
    required this.code,
    this.initial,
    this.canEdit = false,
    this.childId,
    this.childName,
  });

  final String code;
  final Map<String, dynamic>? initial;
  final bool canEdit;
  final int? childId;
  final String? childName;

  @override
  ConsumerState<ChildMilestoneDetailScreen> createState() =>
      _ChildMilestoneDetailScreenState();
}

class _ChildMilestoneDetailScreenState
    extends ConsumerState<ChildMilestoneDetailScreen> {
  Map<String, dynamic>? _milestone;
  final _note = TextEditingController();
  final _weight = TextEditingController();
  final _height = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _addingPhotos = false;
  bool _achieved = false;
  DateTime? _achievedAt;
  int? _currentUserId;

  @override
  void initState() {
    super.initState();
    _apply(widget.initial);
    unawaited(_loadCurrentUserId());
    unawaited(_load());
  }

  @override
  void dispose() {
    _note.dispose();
    _weight.dispose();
    _height.dispose();
    super.dispose();
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

  void _apply(Map<String, dynamic>? m) {
    if (m == null) return;
    _milestone = m;
    _note.text = m['note']?.toString() ?? '';
    _weight.text = _numText(m['weight_kg']);
    _height.text = _numText(m['height_cm']);
    _achieved = m['achieved'] == true;
    final raw = m['achieved_at']?.toString();
    _achievedAt = (raw != null && raw.isNotEmpty) ? DateTime.tryParse(raw) : null;
  }

  String _numText(Object? value) {
    if (value == null) return '';
    if (value is num) {
      return value == value.roundToDouble()
          ? '${value.toInt()}'
          : value.toString();
    }
    return value.toString();
  }

  Future<void> _load() async {
    try {
      final m = await ref
          .read(familychatRepositoryProvider)
          .diaryMilestoneDetail(widget.code);
      if (!mounted) return;
      setState(() {
        _apply(m);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _photos {
    final raw = _milestone?['photos'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Set<int> get _existingAttachmentIds {
    final ids = <int>{};
    for (final photo in _photos) {
      final raw = photo['attachment_id'];
      final id = raw is int ? raw : int.tryParse('$raw');
      if (id != null) ids.add(id);
    }
    return ids;
  }

  String? get _excludeAlbumId {
    final raw = _milestone?['gallery_album_id'];
    if (raw is int) return 'custom:$raw';
    final parsed = int.tryParse('$raw');
    return parsed == null ? null : 'custom:$parsed';
  }

  int? _milestonePhotoId(Map<String, dynamic> photo) {
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  Future<void> _pickDate() async {
    if (!widget.canEdit) return;
    final initial = _achievedAt ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      _achievedAt = picked;
      _achieved = true;
    });
  }

  Future<void> _save() async {
    if (!widget.canEdit || _saving) return;
    setState(() => _saving = true);
    try {
      final data = <String, dynamic>{
        'achieved': _achieved,
        'note': _note.text.trim(),
        if (_achieved && _achievedAt != null)
          'achieved_at': DateFormat('yyyy-MM-dd').format(_achievedAt!),
        if (!_achieved) 'achieved_at': null,
      };
      final w = double.tryParse(_weight.text.trim().replaceAll(',', '.'));
      final h = double.tryParse(_height.text.trim().replaceAll(',', '.'));
      if (_weight.text.trim().isNotEmpty) data['weight_kg'] = w;
      if (_height.text.trim().isNotEmpty) data['height_cm'] = h;
      final m = await ref
          .read(familychatRepositoryProvider)
          .patchDiaryMilestone(widget.code, data);
      if (!mounted) return;
      setState(() {
        _apply(m);
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сохранено')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить')),
      );
    }
  }

  Future<void> _persistBeforeMedia() async {
    if (!_achieved) {
      setState(() {
        _achieved = true;
        _achievedAt ??= DateTime.now();
      });
    }
    _achievedAt ??= DateTime.now();
    final m = await ref.read(familychatRepositoryProvider).patchDiaryMilestone(
      widget.code,
      {
        'achieved': true,
        'achieved_at': DateFormat('yyyy-MM-dd').format(_achievedAt!),
      },
    );
    if (mounted) setState(() => _apply(m));
  }

  Future<void> _addPhotos() async {
    if (!widget.canEdit || _addingPhotos) return;
    final currentUserId = _currentUserId;
    if (currentUserId == null) {
      await _loadCurrentUserId();
    }
    final userId = _currentUserId;
    if (userId == null || !mounted) return;

    await ChatAttachSheet.show(
      context,
      style: ChatAttachSheetStyle.albumMedia,
      familyGalleryUserId: userId,
      familyGalleryChildId: widget.childId,
      familyGalleryChildName: widget.childName,
      excludeFamilyAttachmentIds: _existingAttachmentIds,
      excludeFamilyAlbumId: _excludeAlbumId,
      onSendMedia: (_, items) async {
        await _persistBeforeMedia();
        await _uploadAttachItems(items);
      },
      onAddFromFamilyGallery: (ids) async {
        await _persistBeforeMedia();
        await _linkGalleryAttachments(ids);
      },
    );
  }

  Future<void> _uploadAttachItems(List<ChatAttachSelectionItem> items) async {
    if (items.isEmpty) return;
    setState(() => _addingPhotos = true);
    final repo = ref.read(familychatRepositoryProvider);
    var ok = 0;
    var fail = 0;
    try {
      for (final item in items) {
        if (item.kind != 'image' && item.kind != 'video') continue;
        try {
          final m = await repo.uploadMilestonePhoto(
            widget.code,
            bytes: item.bytes,
            filename: item.filename,
            contentType: item.contentType,
          );
          if (mounted) setState(() => _apply(m));
          final photos = (m['photos'] as List?)?.cast<Map<String, dynamic>>() ??
              const [];
          if (photos.isNotEmpty) {
            final last = photos.last;
            final rawAtt = last['attachment_id'];
            final attachmentId =
                rawAtt is int ? rawAtt : int.tryParse('$rawAtt');
            if (attachmentId != null) {
              await GalleryPhotoLocalState.persistOutgoing(
                uploaded: last,
                localPath: item.localPath,
                assetId: item.assetId,
                filename: item.filename,
                kind: item.kind,
                previewBytes:
                    item.previewBytes.isEmpty ? null : item.previewBytes,
              );
            }
          }
          ok++;
        } catch (_) {
          fail++;
        }
      }
      await _load();
      if (!mounted) return;
      final msg = fail == 0
          ? 'Добавлено: $ok'
          : 'Добавлено: $ok, ошибок: $fail';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _addingPhotos = false);
    }
  }

  Future<void> _linkGalleryAttachments(List<int> attachmentIds) async {
    if (attachmentIds.isEmpty) return;
    setState(() => _addingPhotos = true);
    try {
      final m = await ref
          .read(familychatRepositoryProvider)
          .linkMilestonePhotos(widget.code, attachmentIds);
      if (mounted) setState(() => _apply(m));
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Добавлено: ${attachmentIds.length}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось добавить фото')),
      );
    } finally {
      if (mounted) setState(() => _addingPhotos = false);
    }
  }

  Future<void> _deletePhoto(Map<String, dynamic> photo) async {
    if (!widget.canEdit) return;
    final photoId = _milestonePhotoId(photo);
    if (photoId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить фото?'),
        content: const Text('Фото будет удалено из вехи.'),
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

    try {
      final m = await ref
          .read(familychatRepositoryProvider)
          .deleteMilestonePhoto(widget.code, photoId);
      if (mounted) setState(() => _apply(m));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить фото')),
      );
    }
  }

  Future<void> _openPhoto(int index) async {
    final galleryPhotos = milestonePhotosForGalleryViewer(_photos);
    if (galleryPhotos.isEmpty) return;
    final userId = _currentUserId;
    if (userId == null) return;

    final source = _photos[index.clamp(0, _photos.length - 1)];
    final rawAtt = source['attachment_id'];
    final attId = rawAtt is int ? rawAtt : int.tryParse('$rawAtt');
    var initial = index.clamp(0, galleryPhotos.length - 1);
    if (attId != null) {
      final found = galleryPhotos.indexWhere((p) => p['id'] == attId);
      if (found >= 0) initial = found;
    }

    await GalleryPhotoViewerScreen.open(
      context,
      profileUserId: userId,
      photo: galleryPhotos[initial],
      currentUserId: userId,
      photos: galleryPhotos,
      initialIndex: initial,
    );
  }

  Widget _photoTile(Map<String, dynamic> photo, int index) {
    final url =
        (photo['file_url'] ?? photo['url'] ?? '').toString();
    final threadId = photo['thread_id'];
    final thread = threadId is int ? threadId : int.tryParse('$threadId');

    Widget image;
    if (thread != null && url.isNotEmpty) {
      image = GalleryMediaThumbnail(
        attachment: photo,
        threadId: thread,
        fit: BoxFit.cover,
      );
    } else if (url.isNotEmpty) {
      image = FamilyPublicImage(url: url, fit: BoxFit.cover);
    } else {
      image = ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }

    return GestureDetector(
      onTap: () => _openPhoto(index),
      onLongPress: widget.canEdit ? () => _deletePhoto(photo) : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: image,
          ),
          if (widget.canEdit)
            Positioned(
              right: 2,
              top: 2,
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  onTap: () => _deletePhoto(photo),
                  customBorder: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, color: Colors.white, size: 16),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _milestone?['title']?.toString() ?? 'Веха';
    final photoCount = _photos.length;
    final gridCount = photoCount + (widget.canEdit ? 1 : 0);

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.canEdit)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Сохранить'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Уже умею'),
                  value: _achieved,
                  onChanged: widget.canEdit
                      ? (v) => setState(() {
                            _achieved = v;
                            if (v && _achievedAt == null) {
                              _achievedAt = DateTime.now();
                            }
                          })
                      : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Когда получилось'),
                  subtitle: Text(
                    _achievedAt == null
                        ? '—'
                        : DateFormat('dd.MM.yyyy').format(_achievedAt!),
                  ),
                  trailing: widget.canEdit
                      ? const Icon(Icons.calendar_today_outlined)
                      : null,
                  onTap: widget.canEdit ? _pickDate : null,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _note,
                  enabled: widget.canEdit,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Заметка',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _weight,
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Вес, кг',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _height,
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Рост, см',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Фото',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (_addingPhotos)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (photoCount == 0 && !widget.canEdit)
                  const Text('Пока нет фото вехи')
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: gridCount,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemBuilder: (context, index) {
                      if (widget.canEdit && index == photoCount) {
                        return Material(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: _addingPhotos ? null : _addPhotos,
                            child: const Center(
                              child: Icon(Icons.add_a_photo_outlined),
                            ),
                          ),
                        );
                      }
                      return _photoTile(_photos[index], index);
                    },
                  ),
              ],
            ),
    );
  }
}
