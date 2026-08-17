import '../settings/media_storage_options.dart';

/// Актуальные лимиты кэша и автосейв в галерею. Пишет контроллер настроек.
abstract final class MediaCachePolicy {
  static bool autoSaveIncomingToGallery = false;
  static Duration? stalePeriod = MediaCacheStaleOption.thirtyDays.duration;
  static int maxTotalBytes = MediaCacheSizeOption.gb2.bytes;

  static void apply({
    required bool autoSaveIncomingToGallery,
    required MediaCacheStaleOption stale,
    required MediaCacheSizeOption size,
  }) {
    MediaCachePolicy.autoSaveIncomingToGallery = autoSaveIncomingToGallery;
    stalePeriod = stale.duration;
    maxTotalBytes = size.bytes;
  }
}
