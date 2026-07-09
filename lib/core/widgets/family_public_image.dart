import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? error;

  @override
  Widget build(BuildContext context) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return error ?? const SizedBox.shrink();
    }

    if (kIsWeb) {
      return Image.network(
        trimmed,
        width: width,
        height: height,
        fit: fit,
        gaplessPlayback: true,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return placeholder ?? _defaultPlaceholder(context);
        },
        errorBuilder: (context, _, __) => error ?? _defaultError(context),
      );
    }

    return CachedNetworkImage(
      imageUrl: trimmed,
      width: width,
      height: height,
      fit: fit,
      placeholder: (_, __) => placeholder ?? _defaultPlaceholder(context),
      errorWidget: (_, __, ___) => error ?? _defaultError(context),
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
