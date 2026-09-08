import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/cache/familychat_media_cache.dart';
import '../../../../core/media/gallery_media_utils.dart';
import '../../data/chat_media_display_policy.dart';

/// Лёгкое превью вложения (thumbnail_url / tiny bytes) до полной загрузки.
class ChatAttachmentThumb extends StatelessWidget {
  const ChatAttachmentThumb({
    super.key,
    required this.attachment,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    /// Only tiny / blurry stand-in — never full file_url or large decode.
    this.lightOnly = false,
  });

  final Map<String, dynamic> attachment;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final bool lightOnly;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final memW = lightOnly
        ? ChatMediaDisplayPolicy.lightMemCacheWidthPx(context, width)
        : ChatMediaDisplayPolicy.memCacheWidthPx(context, width);
    final memH = lightOnly
        ? null
        : ChatMediaDisplayPolicy.memCacheHeightPx(context, height);

    if (!lightOnly) {
      final local = attachment['local_bytes'];
      if (isSafeUiPreviewBytes(local)) {
        return _wrap(
          Image.memory(
            local as Uint8List,
            width: width,
            height: height,
            fit: fit,
            cacheWidth: memW,
            cacheHeight: memH,
            gaplessPlayback: true,
          ),
        );
      }
    } else {
      // Tiny downscaled local preview is OK for deferred bubbles.
      final local = attachment['local_bytes'];
      if (isSafeUiPreviewBytes(local) &&
          (local as Uint8List).lengthInBytes <= 48 * 1024) {
        return _wrap(
          _blurred(
            Image.memory(
              local,
              width: width,
              height: height,
              fit: fit,
              cacheWidth: memW,
              gaplessPlayback: true,
            ),
          ),
        );
      }
    }

    final thumbUrl = attachment['thumbnail_url']?.toString().trim() ?? '';
    if (thumbUrl.isNotEmpty) {
      final image = CachedNetworkImage(
        imageUrl: thumbUrl,
        cacheManager: FamilyChatMediaCache.preview,
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: memW,
        memCacheHeight: memH,
        placeholder: (_, __) => _placeholder(scheme),
        errorWidget: (_, __, ___) => _placeholder(scheme),
      );
      return _wrap(lightOnly ? _blurred(image) : image);
    }

    // Full file_url only when not in light-only mode (legacy GIF/CDN previews).
    if (!lightOnly) {
      final fileUrl = attachment['file_url']?.toString().trim() ?? '';
      if (fileUrl.isNotEmpty) {
        return _wrap(
          CachedNetworkImage(
            imageUrl: fileUrl,
            cacheManager: FamilyChatMediaCache.preview,
            width: width,
            height: height,
            fit: fit,
            memCacheWidth: memW,
            memCacheHeight: memH,
            placeholder: (_, __) => _placeholder(scheme),
            errorWidget: (_, __, ___) => _placeholder(scheme),
          ),
        );
      }
    }

    return _placeholder(scheme);
  }

  Widget _blurred(Widget child) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: child,
    );
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
