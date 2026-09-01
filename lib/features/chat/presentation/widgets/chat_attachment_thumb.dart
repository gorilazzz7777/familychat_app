import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/cache/familychat_media_cache.dart';
import '../../../../core/media/gallery_media_utils.dart';

/// Лёгкое превью вложения (thumbnail_url / url) до полной загрузки.
class ChatAttachmentThumb extends StatelessWidget {
  const ChatAttachmentThumb({
    super.key,
    required this.attachment,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  final Map<String, dynamic> attachment;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final local = attachment['local_bytes'];
    if (isSafeUiPreviewBytes(local)) {
      return _wrap(
        Image.memory(
          local,
          width: width,
          height: height,
          fit: fit,
          gaplessPlayback: true,
        ),
      );
    }

    final thumbUrl = attachment['thumbnail_url']?.toString().trim() ?? '';
    final fileUrl = attachment['file_url']?.toString().trim() ?? '';
    final url = thumbUrl.isNotEmpty ? thumbUrl : fileUrl;
    if (url.isNotEmpty) {
      return _wrap(
        CachedNetworkImage(
          imageUrl: url,
          cacheManager: FamilyChatMediaCache.preview,
          width: width,
          height: height,
          fit: fit,
          placeholder: (_, __) => _placeholder(scheme),
          errorWidget: (_, __, ___) => _placeholder(scheme),
        ),
      );
    }

    return _placeholder(scheme);
  }

  Widget _wrap(Widget child) {
    if (borderRadius == null) return child;
    return ClipRRect(borderRadius: borderRadius!, child: child);
  }

  Widget _placeholder(ColorScheme scheme) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
          borderRadius: borderRadius,
        ),
        child: Icon(
          Icons.image_outlined,
          size: 28,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}
