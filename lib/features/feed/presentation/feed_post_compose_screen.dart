import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/media/gallery_media_utils.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_models.dart';
import '../../chat/presentation/widgets/chat_attach_sheet/chat_attach_sheet.dart';
import '../../../core/share/share_to_diary_prefs.dart';
import '../../../core/widgets/share_to_diary_checkbox.dart';
import '../data/feed_post_uploader.dart';

class FeedPostComposeScreen extends ConsumerStatefulWidget {
  const FeedPostComposeScreen({
    super.key,
    this.initialPhotos = const [],
  });

  final List<FeedPostPhoto> initialPhotos;

  @override
  ConsumerState<FeedPostComposeScreen> createState() =>
      _FeedPostComposeScreenState();
}

class _FeedPostComposeScreenState extends ConsumerState<FeedPostComposeScreen> {
  final TextEditingController _captionController = TextEditingController();
  final List<FeedPostPhoto> _photos = [];
  bool _publishing = false;
  String? _error;
  int? _userId;

  @override
  void initState() {
    super.initState();
    if (widget.initialPhotos.isNotEmpty) {
      _photos.addAll(
        widget.initialPhotos.take(FeedPostUploader.maxPhotos),
      );
      for (final photo in _photos) {
        unawaited(FeedPostUploader.cacheLocally(photo));
      }
    }
    unawaited(_loadUserId());
  }

  Future<void> _loadUserId() async {
    try {
      final status = await ref.read(familychatRepositoryProvider).status();
      final id = status['user_id'];
      if (!mounted) return;
      setState(() {
        _userId = id is int ? id : int.tryParse('$id');
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    if (_publishing) return;
    var userId = _userId;
    if (userId == null) {
      await _loadUserId();
      userId = _userId;
    }
    if (userId == null || !mounted) return;

    await ChatAttachSheet.show(
      context,
      style: ChatAttachSheetStyle.albumMedia,
      familyGalleryUserId: userId,
      onSendMedia: (caption, items) async {
        await _appendAttachItems(items);
      },
      onAddFromFamilyGallery: (ids) async {
        await _appendFromFamilyGallery(userId!, ids);
      },
    );
  }

  Future<void> _appendAttachItems(List<ChatAttachSelectionItem> items) async {
    if (items.isEmpty || !mounted) return;

    final photos = <FeedPostPhoto>[];
    for (final item in items) {
      if (item.kind != 'image' && item.kind != 'video') continue;
      final photo = FeedPostPhoto(
        bytes: item.bytes,
        filename: item.filename,
        contentType: item.contentType ?? contentTypeForFilename(item.filename),
        kind: item.kind,
        localPath: item.localPath,
        thumbnailBytes: item.thumbnailBytes,
        cacheId: item.id,
      );
      unawaited(FeedPostUploader.cacheLocally(photo));
      photos.add(photo);
    }
    if (!mounted || photos.isEmpty) return;
    _appendPhotos(photos);
  }

  Future<void> _appendFromFamilyGallery(
    int userId,
    List<int> attachmentIds,
  ) async {
    if (attachmentIds.isEmpty || !mounted) return;
    final repo = ref.read(familychatRepositoryProvider);
    final wanted = attachmentIds.toSet();
    final found = <int, Map<String, dynamic>>{};
    var offset = 0;
    while (found.length < wanted.length && offset < 600) {
      final data = await repo.memberGalleryPickablePhotos(
        userId,
        offset: offset,
        limit: 60,
      );
      final batch = (data['photos'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (batch.isEmpty) break;
      for (final photo in batch) {
        final id = photo['id'];
        final aid = id is int ? id : int.tryParse('$id');
        if (aid != null && wanted.contains(aid)) {
          found[aid] = photo;
        }
      }
      offset += batch.length;
      final total = data['total'] is int
          ? data['total'] as int
          : int.tryParse('${data['total']}') ?? 0;
      if (offset >= total) break;
    }

    final photos = <FeedPostPhoto>[];
    for (final id in attachmentIds) {
      final meta = found[id];
      if (meta == null) continue;
      final threadId = meta['thread_id'] is int
          ? meta['thread_id'] as int
          : int.tryParse('${meta['thread_id']}');
      if (threadId == null) continue;
      try {
        final bytes = await repo.fetchChatAttachmentBytes(threadId, id);
        if (bytes.isEmpty) continue;
        final filename = meta['filename']?.toString() ?? 'photo_$id.jpg';
        final kind = isVideoAttachment(meta) ? 'video' : 'image';
        final photo = FeedPostPhoto(
          bytes: bytes,
          filename: filename,
          contentType: meta['content_type']?.toString() ??
              contentTypeForFilename(filename),
          kind: kind,
          cacheId: 'gallery_$id',
        );
        unawaited(FeedPostUploader.cacheLocally(photo));
        photos.add(photo);
      } catch (_) {}
    }
    if (!mounted || photos.isEmpty) return;
    _appendPhotos(photos);
  }

  void _appendPhotos(List<FeedPostPhoto> photos) {
    final merged = [..._photos, ...photos];
    if (merged.length > FeedPostUploader.maxPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Можно выбрать не более ${FeedPostUploader.maxPhotos} фото. '
            'Добавлены первые ${FeedPostUploader.maxPhotos}.',
          ),
        ),
      );
    }
    setState(() {
      _photos
        ..clear()
        ..addAll(merged.take(FeedPostUploader.maxPhotos));
      _error = null;
    });
  }

  Future<void> _publish() async {
    if (_photos.isEmpty || _publishing) return;
    final caption = _captionController.text.trim();
    if (caption.length > FeedPostUploader.maxCaptionLength) {
      setState(
        () => _error =
            'Описание не длиннее ${FeedPostUploader.maxCaptionLength} символов',
      );
      return;
    }

    setState(() {
      _publishing = true;
      _error = null;
    });

    Map<String, dynamic> actor = {'name': 'Вы'};
    try {
      final status = await ref.read(familychatRepositoryProvider).status();
      final profile = status['profile'];
      if (profile is Map) {
        actor = {
          'user_id': status['user_id'],
          'name': profile['display_name']?.toString() ?? 'Вы',
          'avatar_url': profile['avatar_url']?.toString(),
          'gender': profile['gender']?.toString(),
        };
      } else {
        actor = {
          'user_id': status['user_id'],
          'name': 'Вы',
        };
      }
    } catch (_) {}

    final snapshot = List<FeedPostPhoto>.from(_photos);
    final optimistic = FeedPostUploader.buildOptimisticEvent(
      photos: snapshot,
      caption: caption,
      actor: actor,
    );

    FeedPostUploader.publishInBackground(
      repo: ref.read(familychatRepositoryProvider),
      photos: snapshot,
      caption: caption,
      shareToDiary: ref.read(shareToDiaryPrefsProvider),
    );

    if (!mounted) return;
    Navigator.of(context).pop(optimistic);
  }

  @override
  Widget build(BuildContext context) {
    final captionLength = _captionController.text.length;

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'В ленту',
        actions: [
          TextButton(
            onPressed: _photos.isEmpty || _publishing ? null : _publish,
            child: _publishing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Опубликовать'),
          ),
        ],
      ),
      body: _photos.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Выберите фото или видео для публикации в семейную ленту',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _publishing ? null : _pickMedia,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Добавить медиа'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SizedBox(
                  height: 108,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _photos.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, index) {
                      if (index == _photos.length) {
                        return InkWell(
                          onTap: _publishing ? null : _pickMedia,
                          child: Container(
                            width: 108,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                              ),
                            ),
                            child:
                                const Icon(Icons.add_photo_alternate_outlined),
                          ),
                        );
                      }
                      final photo = _photos[index];
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              photo.previewBytes,
                              width: 108,
                              height: 108,
                              fit: BoxFit.cover,
                            ),
                          ),
                          if (photo.kind == 'video')
                            const Positioned.fill(
                              child: Center(
                                child: Icon(
                                  Icons.play_circle_fill,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: IconButton.filledTonal(
                              style: IconButton.styleFrom(
                                minimumSize: const Size(28, 28),
                                padding: EdgeInsets.zero,
                              ),
                              onPressed: _publishing
                                  ? null
                                  : () =>
                                      setState(() => _photos.removeAt(index)),
                              icon: const Icon(Icons.close, size: 16),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                const ShareToDiaryCheckbox(dense: true),
                const SizedBox(height: 8),
                TextField(
                  controller: _captionController,
                  minLines: 2,
                  maxLines: 6,
                  maxLength: FeedPostUploader.maxCaptionLength,
                  decoration: const InputDecoration(
                    labelText: 'Описание',
                    hintText: 'Расскажите, что на фото...',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_photos.length} из ${FeedPostUploader.maxPhotos} фото',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (captionLength >
                    FeedPostUploader.maxCaptionLength - 40) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Осталось ${math.max(0, FeedPostUploader.maxCaptionLength - captionLength)} символов',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
    );
  }
}
