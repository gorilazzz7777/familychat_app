import 'package:flutter/material.dart';

import '../../../core/media/media_local_index.dart';
import 'gallery_media_thumbnail.dart';

int? _galleryAlbumCoverThreadId(Map<String, dynamic>? cover) {
  if (cover == null) return null;
  final raw = cover['thread_id'];
  if (raw is int) return raw;
  return int.tryParse('$raw');
}

/// Stable album cover: keeps attachment map and avoids re-decode on parent rebuild.
class GalleryAlbumCover extends StatefulWidget {
  const GalleryAlbumCover({
    super.key,
    required this.cover,
    this.threadId,
    this.fallbackIcon = Icons.photo_library_outlined,
  });

  final Map<String, dynamic>? cover;
  final int? threadId;
  final IconData fallbackIcon;

  @override
  State<GalleryAlbumCover> createState() => _GalleryAlbumCoverState();
}

class _GalleryAlbumCoverState extends State<GalleryAlbumCover> {
  Map<String, dynamic>? _resolvedCover;
  int? _coverId;

  @override
  void initState() {
    super.initState();
    _applyCover(widget.cover);
  }

  @override
  void didUpdateWidget(covariant GalleryAlbumCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextId = _coverIdOf(widget.cover);
    if (nextId != _coverId || oldWidget.threadId != widget.threadId) {
      _applyCover(widget.cover);
    }
  }

  void _applyCover(Map<String, dynamic>? cover) {
    _coverId = _coverIdOf(cover);
    if (cover == null) {
      _resolvedCover = null;
      return;
    }
    _resolvedCover = Map<String, dynamic>.from(cover);
    MediaLocalIndex.hydrateAttachment(_resolvedCover!);
  }

  int? _coverIdOf(Map<String, dynamic>? cover) {
    if (cover == null) return null;
    final id = cover['id'];
    return id is int ? id : int.tryParse('$id');
  }

  @override
  Widget build(BuildContext context) {
    final cover = _resolvedCover;
    if (cover == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Center(
          child: Icon(
            widget.fallbackIcon,
            size: 40,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: GalleryMediaThumbnail(
        key: ValueKey('album_cover_$_coverId'),
        attachment: cover,
        threadId: widget.threadId ?? _galleryAlbumCoverThreadId(cover),
        fit: BoxFit.cover,
        lazyPreview: false,
      ),
    );
  }
}
