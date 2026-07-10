import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'family_public_web_image.dart';
import '../cache/familychat_media_cache.dart';

/// Публичные URL (аватары в S3). На web — [Image.network], без cache_manager (ему нужен CORS).
class FamilyPublicImage extends StatelessWidget {
  const FamilyPublicImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.error,
    this.cacheManager,
    this.useMediaCache = true,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? error;
  final CacheManager? cacheManager;
  final bool useMediaCache;

  @override
  Widget build(BuildContext context) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return error ?? const SizedBox.shrink();
    }

    if (kIsWeb) {
      return FamilyPublicWebImage(
        url: trimmed,
        width: width,
        height: height,
        fit: fit,
        placeholder: placeholder,
        error: error,
      );
    }

    final manager = cacheManager ??
        (useMediaCache ? FamilyChatMediaCache.preview : null);

    return CachedNetworkImage(
      imageUrl: trimmed,
      cacheManager: manager,
      useOldImageOnUrlChange: true,
      width: width,
      height: height,
      fit: fit,
      placeholder: (_, __) => placeholder ?? _defaultPlaceholder(context),
      errorWidget: (_, __, ___) => error ?? _defaultError(context),
      imageBuilder: (context, imageProvider) {
        if (useMediaCache) {
          unawaited(FamilyChatMediaCache.trimIfNeeded());
        }
        return Image(
          image: imageProvider,
          width: width,
          height: height,
          fit: fit,
          gaplessPlayback: true,
        );
      },
    );
  }

  static Widget _defaultPlaceholder(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }

  static Widget _defaultError(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.person_outline,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
