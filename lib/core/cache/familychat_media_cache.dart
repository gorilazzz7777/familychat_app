import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../media/media_cache_policy.dart';

/// Дисковый кэш превью и полноэкранных изображений FamilyChat.
/// Срок и объём задаёт [MediaCachePolicy]; менеджер сам почти не вытесняет.
abstract final class FamilyChatMediaCache {
  static const maxObjects = 500000;
  static const _managerStalePeriod = Duration(days: 3650);

  static final CacheManager preview = CacheManager(
    Config(
      'familychat_preview_cache',
      stalePeriod: _managerStalePeriod,
      maxNrOfCacheObjects: maxObjects,
    ),
  );

  static final CacheManager fullscreen = CacheManager(
    Config(
      'familychat_fullscreen_cache',
      stalePeriod: _managerStalePeriod,
      maxNrOfCacheObjects: maxObjects,
    ),
  );

  static DateTime? _lastTrimAt;

  /// Обрезает кэш по сроку и объёму из настроек (LRU).
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
    final repo = manager.config.repo;
    await repo.open();
    var objects = await repo.getAllObjects();
    if (objects.isEmpty) return;

    final stale = MediaCachePolicy.stalePeriod;
    if (stale != null) {
      final cutoff = DateTime.now().subtract(stale);
      for (final obj in List.of(objects)) {
        final touched = obj.touched ?? DateTime.fromMillisecondsSinceEpoch(0);
        if (touched.isBefore(cutoff)) {
          await store.removeCachedFile(obj);
        }
      }
      objects = await repo.getAllObjects();
    }

    var totalBytes = await store.getCacheSize();
    final limit = MediaCachePolicy.maxTotalBytes;
    if (totalBytes <= limit) return;
    if (objects.isEmpty) return;

    objects.sort((a, b) {
      final at = a.touched ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.touched ?? DateTime.fromMillisecondsSinceEpoch(0);
      return at.compareTo(bt);
    });
    for (final obj in objects) {
      if (totalBytes <= limit) break;
      await store.removeCachedFile(obj);
      totalBytes -= obj.length ?? 0;
    }
  }
}
