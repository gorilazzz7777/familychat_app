import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/media/gallery_device_media_store.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/gallery_photo_local_state.dart';
import '../../../core/media/gallery_video_thumbnail.dart';
import '../../../core/media/local_device_file.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../../core/widgets/lazy_visibility.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';

/// Превью медиа в сетке галереи: фото или кадр видео с иконкой play.
class GalleryMediaThumbnail extends StatefulWidget {
  const GalleryMediaThumbnail({
    super.key,
    required this.attachment,
    this.threadId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.lazyPreview = true,
  });

  final Map<String, dynamic> attachment;
  final int? threadId;
  final double? width;
  final double? height;
  final BoxFit fit;
  /// Отложить генерацию превью, пока ячейка не видна в viewport.
  final bool lazyPreview;

  @override
  State<GalleryMediaThumbnail> createState() => _GalleryMediaThumbnailState();
}

class _GalleryMediaThumbnailState extends State<GalleryMediaThumbnail> {
  String? _videoThumbPath;
  bool _videoThumbLoading = false;
  int _videoGen = 0;
  int _photoGen = 0;
  bool _previewRequested = false;

  @override
  void initState() {
    super.initState();
    if (!widget.lazyPreview) {
      _requestPreviews();
    }
  }

  @override
  void didUpdateWidget(covariant GalleryMediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameMedia(oldWidget.attachment, widget.attachment) &&
        oldWidget.threadId == widget.threadId &&
        oldWidget.lazyPreview == widget.lazyPreview) {
      return;
    }
    if (!widget.lazyPreview || _previewRequested) {
      unawaited(_ensurePhotoPreview());
      unawaited(_loadVideoThumbIfNeeded());
    }
  }

  void _requestPreviews() {
    if (_previewRequested) return;
    _previewRequested = true;
    unawaited(_ensurePhotoPreview());
    unawaited(_loadVideoThumbIfNeeded());
  }

  Future<void> _ensurePhotoPreview() async {
    if (isVideoAttachment(widget.attachment)) return;
    if (GalleryPhotoLocalState.previewBytesOf(widget.attachment) != null) {
      return;
    }
    final gen = ++_photoGen;
    await GalleryPhotoLocalState.hydratePreviewBytes(widget.attachment);
    if (!mounted || gen != _photoGen) return;
    if (GalleryPhotoLocalState.previewBytesOf(widget.attachment) != null) {
      setState(() {});
    }
  }

  bool _sameMedia(Map<String, dynamic> a, Map<String, dynamic> b) {
    return a['id'] == b['id'] &&
        a['file_url'] == b['file_url'] &&
        a['local_device_path'] == b['local_device_path'] &&
        a['thumbnail_url'] == b['thumbnail_url'];
  }

  int? _threadIdOf(Map<String, dynamic> attachment) {
    if (widget.threadId != null) return widget.threadId;
    final raw = attachment['thread_id'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  bool _hasRemoteVideoThumb(Map<String, dynamic> attachment) {
    return attachment['thumbnail_url']?.toString().trim().isNotEmpty ?? false;
  }

  Future<void> _loadVideoThumbIfNeeded() async {
    final attachment = widget.attachment;
    await MediaLocalIndex.ensureLoaded();
    if (!mounted) return;
    MediaLocalIndex.hydrateAttachment(attachment);
    if (!isVideoAttachment(attachment)) {
      if (_videoThumbPath != null || _videoThumbLoading) {
        setState(() {
          _videoThumbPath = null;
          _videoThumbLoading = false;
        });
      }
      return;
    }

    if (_hasRemoteVideoThumb(attachment)) return;
    if (isSafeUiPreviewBytes(attachment['local_bytes']) ||
        isSafeUiPreviewBytes(attachment['thumbnail_bytes'])) {
      return;
    }

    final gen = ++_videoGen;
    setState(() => _videoThumbLoading = true);
    final path = await GalleryVideoThumbnail.ensureForAttachment(attachment);
    if (!mounted || gen != _videoGen) return;
    setState(() {
      _videoThumbPath = path;
      _videoThumbLoading = false;
    });
  }

  Key get _visibilityKey {
    final id = widget.attachment['id'];
    return ValueKey('gallery_thumb_$id');
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    if (!widget.lazyPreview) return content;
    return LazyVisibility(
      visibilityKey: _visibilityKey,
      onVisible: _requestPreviews,
      child: content,
    );
  }

  Widget _buildContent() {
    final attachment = widget.attachment;
    MediaLocalIndex.hydrateAttachment(attachment);
    final fit = widget.fit;

    if (isVideoAttachment(attachment)) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _videoBackground(attachment, fit),
          Center(
            child: Icon(
              Icons.play_circle_outline,
              size: (widget.width != null && widget.width! < 80) ? 28 : 40,
              color: Colors.white70,
            ),
          ),
        ],
      );
    }

    return _photo(attachment, fit);
  }

  Widget _videoBackground(Map<String, dynamic> attachment, BoxFit fit) {
    final localPreview = safeUiPreviewBytes(
      thumbnailBytes: attachment['thumbnail_bytes'] is Uint8List
          ? attachment['thumbnail_bytes'] as Uint8List
          : null,
      bytes: attachment['local_bytes'] is Uint8List
          ? attachment['local_bytes'] as Uint8List
          : null,
      kind: 'image',
    );
    if (localPreview != null) {
      return Image.memory(
        localPreview,
        fit: fit,
        gaplessPlayback: true,
        width: widget.width,
        height: widget.height,
      );
    }

    final thumbPath = _videoThumbPath;
    if (thumbPath != null && thumbPath.isNotEmpty) {
      return localDeviceFileImage(
        path: thumbPath,
        fit: fit,
        width: widget.width,
        height: widget.height,
        error: const ColoredBox(color: Color(0xFF1A1A1A)),
      );
    }

    final thumbUrl = attachment['thumbnail_url']?.toString().trim() ?? '';
    if (thumbUrl.isNotEmpty) {
      return FamilyPublicImage(
        url: thumbUrl,
        localPath: GalleryDeviceMediaStore.existingLocalPath(attachment),
        width: widget.width,
        height: widget.height,
        fit: fit,
        error: const ColoredBox(color: Color(0xFF1A1A1A)),
      );
    }

    return ColoredBox(
      color: const Color(0xFF1A1A1A),
      child: _videoThumbLoading
          ? const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : null,
    );
  }

  Widget _photo(Map<String, dynamic> attachment, BoxFit fit) {
    final preview = GalleryPhotoLocalState.previewBytesOf(attachment);
    if (preview != null) {
      return Image.memory(
        preview,
        width: widget.width,
        height: widget.height,
        fit: fit,
        gaplessPlayback: true,
      );
    }

    final threadId = _threadIdOf(attachment);
    if (threadId != null) {
      return ChatNetworkImage(
        threadId: threadId,
        attachment: attachment,
        width: widget.width,
        height: widget.height,
        fit: fit,
      );
    }
    return FamilyPublicImage(
      url: galleryAttachmentUrl(attachment),
      attachment: attachment,
      width: widget.width,
      height: widget.height,
      fit: fit,
      placeholder: const Center(child: CircularProgressIndicator()),
      error: const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}
