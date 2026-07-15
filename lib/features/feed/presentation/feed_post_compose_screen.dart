import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/video_upload_pipeline.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_media_drafts_sheet.dart';
import '../../profile/presentation/album_upload_file_bytes.dart';
import '../data/feed_post_uploader.dart';

class FeedPostComposeScreen extends ConsumerStatefulWidget {
  const FeedPostComposeScreen({super.key});

  @override
  ConsumerState<FeedPostComposeScreen> createState() => _FeedPostComposeScreenState();
}

class _FeedPostComposeScreenState extends ConsumerState<FeedPostComposeScreen> {
  final TextEditingController _captionController = TextEditingController();
  final List<FeedPostPhoto> _photos = [];
  bool _publishing = false;
  String? _error;

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _pickFromPhoneGallery() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: kIsWeb,
      type: FileType.media,
    );
    if (!mounted || picked == null || picked.files.isEmpty) return;

    final photos = <FeedPostPhoto>[];
    for (final file in picked.files) {
      final bytes = await readAlbumUploadFileBytes(file);
      if (bytes == null || bytes.isEmpty) continue;
      final kind = mediaDraftKindFor(
        filename: file.name,
        bytes: bytes,
      );
      if (kind == MediaDraftKind.video) {
        if (!mounted) return;
        final draft = await showMediaProgressDialog<MediaUploadDraft>(
          context: context,
          title: 'Подготовка видео',
          work: (report) => prepareVideoUploadDraft(
            originalBytes: bytes,
            filename: file.name,
            contentType: contentTypeForFilename(file.name),
            localPath: file.path,
            onProgress: report,
          ),
        );
        if (draft == null || !draft.canUpload) continue;
        photos.add(
          FeedPostPhoto(
            bytes: draft.bytesForUpload,
            filename: draft.filename,
            contentType: draft.contentType,
            photoExif: draft.geo?.toPhotoExif(),
          ),
        );
      } else if (kind == MediaDraftKind.image) {
        photos.add(
          FeedPostPhoto(
            bytes: bytes,
            filename: file.name,
            contentType: _contentTypeForFilename(file.name),
          ),
        );
      }
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

  String _contentTypeForFilename(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  Future<void> _publish() async {
    if (_photos.isEmpty || _publishing) return;
    final caption = _captionController.text.trim();
    if (caption.length > FeedPostUploader.maxCaptionLength) {
      setState(() => _error = 'Описание не длиннее ${FeedPostUploader.maxCaptionLength} символов');
      return;
    }

    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      await FeedPostUploader.publish(
        repo: ref.read(familychatRepositoryProvider),
        photos: _photos,
        caption: caption,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = e.toString();
      });
    }
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
                      'Выберите фото для публикации в семейную ленту',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _publishing ? null : _pickFromPhoneGallery,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Галерея телефона'),
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
                          onTap: _publishing ? null : _pickFromPhoneGallery,
                          child: Container(
                            width: 108,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outlineVariant,
                              ),
                            ),
                            child: const Icon(Icons.add_photo_alternate_outlined),
                          ),
                        );
                      }
                      final photo = _photos[index];
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              photo.bytes,
                              width: 108,
                              height: 108,
                              fit: BoxFit.cover,
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
                                  : () => setState(() => _photos.removeAt(index)),
                              icon: const Icon(Icons.close, size: 16),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
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
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                if (captionLength > FeedPostUploader.maxCaptionLength - 40) ...[
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
