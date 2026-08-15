import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../../core/cache/familychat_media_cache.dart';
import '../../../../../core/media/gallery_media_utils.dart';

/// Прогрев дискового и memory-кэша фото для альбома «Мой дневник».
abstract final class ScrapbookMediaPrefetch {
  static const _maxConcurrent = 6;

  /// Скачивает все фото в [FamilyChatMediaCache] и (если есть context)
  /// кладёт их в [ImageCache], чтобы при листании не было спиннеров.
  static Future<void> prefetch(
    Iterable<Map<String, dynamic>> media, {
    BuildContext? context,
  }) async {
    final urls = <String>{};
    for (final item in media) {
      if (isVideoAttachment(item)) continue;
      final url = galleryAttachmentUrl(item).trim();
      if (url.isNotEmpty) urls.add(url);
    }
    if (urls.isEmpty) return;

    final pending = urls.toList();
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= pending.length) return;
        await _warmOne(pending[i], context);
      }
    }

    final workers = List.generate(
      _maxConcurrent.clamp(1, pending.length),
      (_) => worker(),
    );
    await Future.wait(workers);
  }

  static Future<void> _warmOne(String url, BuildContext? context) async {
    final ctx = context;
    if (ctx == null || !ctx.mounted) return;
    try {
      if (kIsWeb) {
        // На web не трогаем cache manager (XHR + CORS): греем через NetworkImage.
        await precacheImage(
          NetworkImage(url),
          ctx,
        );
        return;
      }
      final file = await FamilyChatMediaCache.preview.getSingleFile(url);
      if (!ctx.mounted) return;
      await precacheImage(FileImage(file), ctx);
      if (!ctx.mounted) return;
      await precacheImage(
        CachedNetworkImageProvider(
          url,
          cacheManager: FamilyChatMediaCache.preview,
        ),
        ctx,
      );
    } on Object {
      // Prefetch best-effort — страница и так покажет kraft-placeholder.
    }
  }
}

/// Фото альбома: диск-кэш + без спиннера (вместо него цвет бумаги).
class ScrapbookCachedPhoto extends StatelessWidget {
  const ScrapbookCachedPhoto({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
  });

  final String url;
  final BoxFit fit;

  static const _paper = Color(0xFFF7F0E4);

  @override
  Widget build(BuildContext context) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return const ColoredBox(color: _paper);
    }

    if (kIsWeb) {
      // CanvasKit по умолчанию качает картинку XHR (нужен CORS на S3).
      // HTML <img> показывает публичные объекты без CORS.
      return Image.network(
        trimmed,
        fit: fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return const ColoredBox(color: _paper);
        },
        errorBuilder: (_, __, ___) => const ColoredBox(
          color: _paper,
          child: Center(
            child: Icon(Icons.broken_image_outlined, color: Color(0xFF8B7355)),
          ),
        ),
      );
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Ограничиваем decode для быстрого листания (типичный кадр альбома ~800px).
    final memW = (800 * dpr).round().clamp(400, 1600);

    return CachedNetworkImage(
      imageUrl: trimmed,
      cacheManager: FamilyChatMediaCache.preview,
      fit: fit,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholderFadeInDuration: Duration.zero,
      useOldImageOnUrlChange: true,
      memCacheWidth: memW,
      placeholder: (_, __) => const ColoredBox(color: _paper),
      errorWidget: (_, __, ___) => const ColoredBox(
        color: _paper,
        child: Center(
          child: Icon(Icons.broken_image_outlined, color: Color(0xFF8B7355)),
        ),
      ),
      imageBuilder: (context, imageProvider) {
        return Image(
          image: imageProvider,
          fit: fit,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        );
      },
    );
  }
}
