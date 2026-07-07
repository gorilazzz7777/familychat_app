import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Дисковый кэш превью и полноэкранных изображений FamilyChat.
abstract final class FamilyChatMediaCache {
  static const stalePeriod = Duration(days: 20);
  static const maxTotalBytes = 2 * 1024 * 1024 * 1024; // 2 ГБ
  static const maxObjects = 500000;

  static final CacheManager preview = CacheManager(
    Config(
      'familychat_preview_cache',
      stalePeriod: stalePeriod,
      maxNrOfCacheObjects: maxObjects,
    ),
  );

  static final CacheManager fullscreen = CacheManager(
    Config(
      'familychat_fullscreen_cache',
      stalePeriod: stalePeriod,
      maxNrOfCacheObjects: maxObjects,
    ),
  );

  static DateTime? _lastTrimAt;

  /// Обрезает кэш по общему объёму (LRU). Срок 20 дней обрабатывает flutter_cache_manager.
  static Future<void> trimIfNeeded({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastTrimAt != null &&
        now.difference(_lastTrimAt!) < const Duration(minutes: 5)) {
      return;
    }
    _lastTrimAt = now;
    await _trimManager(preview);
    await _trimManager(fullscreen);
  }

  static Future<void> _trimManager(CacheManager manager) async {
    final store = manager.store;
    var totalBytes = await store.getCacheSize();
    if (totalBytes <= maxTotalBytes) return;

    final repo = manager.config.repo;
    await repo.open();
    final objects = await repo.getAllObjects();
    if (objects.isEmpty) return;

    objects.sort((a, b) {
      final at = a.touched ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.touched ?? DateTime.fromMillisecondsSinceEpoch(0);
      return at.compareTo(bt);
    });
    for (final obj in objects) {
      if (totalBytes <= maxTotalBytes) break;
      await store.removeCachedFile(obj);
      totalBytes -= obj.length ?? 0;
    }
  }
}
