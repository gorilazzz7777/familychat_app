import 'dart:async';
import 'dart:collection';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import '../../../core/cache/familychat_media_cache.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../chat/data/chat_media_flicker_trace.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';
import '../../familychat/data/familychat_repository.dart';
import 'feed_jank_log.dart';
import 'feed_scroll_busy.dart';

/// Prefetch feed cover photos into [FamilyChatMediaCache.preview] around the
/// viewport (±[radius] posts). Fling stays light: disk fetch only while
/// flinging; decode into ImageCache when not flinging.
class FeedMediaPrefetch {
  FeedMediaPrefetch._();

  /// Keep this many covers above **and** below the centered post.
  static const radius = 5;
  static const maxConcurrentIdle = 2;
  static const maxConcurrentBusy = 2;
  /// Rough average card height for index estimate (calibrate via logs).
  static const approxPostHeight = 480.0;

  static final Set<String> _done = {};
  static final Set<String> _inflightKeys = {};
  static final Queue<_PrefetchItem> _queue = Queue();
  static int _active = 0;
  static BuildContext? _context;
  static FamilyChatRepository? _repo;
  static Timer? _throttle;
  static int _lastCenter = -1;

  static void bind({
    required BuildContext context,
    required FamilyChatRepository repo,
  }) {
    _context = context;
    _repo = repo;
  }

  static void clearSession() {
    _throttle?.cancel();
    _throttle = null;
    _queue.clear();
    _inflightKeys.clear();
    _lastCenter = -1;
    // Keep _done — same session revisit should stay warm.
  }

  /// Warm covers for posts in `[center - radius, center + radius]`.
  /// Closest posts are queued first.
  static void ensureAround({
    required List<Map<String, dynamic>> events,
    required int centerIndex,
  }) {
    final repo = _repo;
    if (repo == null || events.isEmpty) return;
    final center = centerIndex.clamp(0, events.length - 1);
    _lastCenter = center;

    final order = <int>[center];
    for (var d = 1; d <= radius; d++) {
      final up = center - d;
      final down = center + d;
      if (up >= 0) order.add(up);
      if (down < events.length) order.add(down);
    }

    // Rebuild priority: near posts jump the queue.
    final pending = <_PrefetchItem>[];
    for (final i in order) {
      final photos = feedEventPrefetchPhotos(events[i]);
      if (photos.isEmpty) continue;
      final item = _itemForPhoto(photos.first, repo);
      if (item == null) continue;
      if (_done.contains(item.cacheKey) ||
          _inflightKeys.contains(item.cacheKey)) {
        continue;
      }
      pending.add(item);
    }
    if (pending.isEmpty) {
      _pump();
      return;
    }

    // Drop far items already waiting; keep only the new window (plus inflight).
    final keepKeys = pending.map((e) => e.cacheKey).toSet();
    _queue.removeWhere((e) => !keepKeys.contains(e.cacheKey));
    final queued = _queue.map((e) => e.cacheKey).toSet();
    for (final item in pending.reversed) {
      if (queued.contains(item.cacheKey)) continue;
      _queue.addFirst(item);
      queued.add(item.cacheKey);
    }
    FeedJankLog.log(
      'PREFETCH window center=$center '
      'range=${(center - radius).clamp(0, events.length - 1)}..'
      '${(center + radius).clamp(0, events.length - 1)} '
      'queued=${_queue.length} done=${_done.length}',
    );
    _pump();
  }

  /// Backward-compatible alias.
  static void ensureAhead({
    required List<Map<String, dynamic>> events,
    required int fromIndex,
  }) =>
      ensureAround(events: events, centerIndex: fromIndex);

  /// Throttled scroll hook — cheap approx index from pixels.
  static void onScroll({
    required List<Map<String, dynamic>> events,
    required double pixels,
  }) {
    if (events.isEmpty) return;
    final approx =
        (pixels / approxPostHeight).floor().clamp(0, events.length - 1);
    // Hot path: if center moved, refresh window immediately (no long wait).
    if (approx != _lastCenter) {
      _throttle?.cancel();
      ensureAround(events: events, centerIndex: approx);
      return;
    }
    _throttle?.cancel();
    _throttle = Timer(const Duration(milliseconds: 48), () {
      if (events.isEmpty) return;
      final again =
          (pixels / approxPostHeight).floor().clamp(0, events.length - 1);
      ensureAround(events: events, centerIndex: again);
    });
  }

  /// Warm a single attachment (e.g. next carousel page after user swipe).
  static void enqueueAttachment(Map<String, dynamic> photo) {
    final repo = _repo;
    if (repo == null) return;
    final item = _itemForPhoto(photo, repo);
    if (item == null) return;
    if (_done.contains(item.cacheKey) ||
        _inflightKeys.contains(item.cacheKey)) {
      return;
    }
    if (!_queue.any((e) => e.cacheKey == item.cacheKey)) {
      _queue.addFirst(item);
    }
    _pump();
  }

  static _PrefetchItem? _itemForPhoto(
    Map<String, dynamic> photo,
    FamilyChatRepository repo,
  ) {
    final threadId = photo['thread_id'] is int
        ? photo['thread_id'] as int
        : int.tryParse('${photo['thread_id']}');
    final attachmentId = photo['id'] is int
        ? photo['id'] as int
        : int.tryParse('${photo['id'] ?? photo['attachment_id']}');
    if (threadId == null || attachmentId == null) return null;

    final cacheKey = chatAttachmentStableCacheKey(
          threadId: threadId,
          attachmentId: attachmentId,
        ) ??
        'feed_$threadId:$attachmentId';

    final url = chatAttachmentImageUrl(
      repo: repo,
      threadId: threadId,
      attachment: photo,
    );
    if (url.isEmpty) return null;
    return _PrefetchItem(cacheKey: cacheKey, url: url);
  }

  static void _enqueuePhoto(
    Map<String, dynamic> photo,
    FamilyChatRepository repo,
  ) {
    final item = _itemForPhoto(photo, repo);
    if (item == null) return;
    if (_done.contains(item.cacheKey) ||
        _inflightKeys.contains(item.cacheKey)) {
      return;
    }
    if (_queue.any((e) => e.cacheKey == item.cacheKey)) return;
    _queue.add(item);
  }

  static void _pump() {
    final limit =
        FeedScrollBusy.isBusy ? maxConcurrentBusy : maxConcurrentIdle;
    while (_active < limit && _queue.isNotEmpty) {
      final item = _queue.removeFirst();
      if (_done.contains(item.cacheKey) ||
          _inflightKeys.contains(item.cacheKey)) {
        continue;
      }
      _inflightKeys.add(item.cacheKey);
      _active++;
      unawaited(_run(item).whenComplete(() {
        _inflightKeys.remove(item.cacheKey);
        _active--;
        _pump();
      }));
    }
  }

  static Future<void> _run(_PrefetchItem item) async {
    try {
      // Disk warm is cheap if already cached; safe while the list is moving.
      await FamilyChatMediaCache.preview.getSingleFile(item.url);
      // Decode into ImageCache only when the feed is fully idle — mid-drag
      // precache was causing 50–70ms build hitches on slow scroll.
      if (FeedScrollBusy.isBusy) {
        FeedJankLog.log('PREFETCH disk key=${item.cacheKey}');
        FeedScrollBusy.onIdle(() {
          if (_done.contains(item.cacheKey) ||
              _inflightKeys.contains(item.cacheKey)) {
            return;
          }
          if (!_queue.any((e) => e.cacheKey == item.cacheKey)) {
            _queue.addFirst(item);
          }
          _pump();
        });
        return;
      }
      final ctx = _context;
      if (ctx != null && ctx.mounted) {
        final provider = CachedNetworkImageProvider(
          item.url,
          cacheKey: item.cacheKey,
          cacheManager: FamilyChatMediaCache.preview,
        );
        await precacheImage(provider, ctx);
      }
      _done.add(item.cacheKey);
      FeedJankLog.log('PREFETCH ok key=${item.cacheKey}');
    } catch (_) {
      // Soft-fail; leave out of _done so the next window can retry.
      FeedJankLog.log('PREFETCH fail key=${item.cacheKey}');
    }
  }
}

class _PrefetchItem {
  const _PrefetchItem({required this.cacheKey, required this.url});
  final String cacheKey;
  final String url;
}

/// First-screen photos for a feed event (same rules as the card, slimmed).
List<Map<String, dynamic>> feedEventPrefetchPhotos(Map<String, dynamic> event) {
  final kind = event['kind']?.toString() ?? '';
  final payload = (event['payload'] as Map<String, dynamic>?) ?? const {};
  final atts = (payload['attachments'] as List<dynamic>? ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  int? asInt(Object? v) {
    if (v is int) return v;
    return int.tryParse('$v');
  }

  final payloadThread = asInt(payload['thread_id']);

  bool isImage(Map<String, dynamic> att) {
    final k = att['kind']?.toString();
    if (k == 'image' || k == 'video') return true;
    final name = att['filename']?.toString().toLowerCase() ?? '';
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp') ||
        name.endsWith('.heic');
  }

  Map<String, dynamic> normalize(Map<String, dynamic> att) {
    final tid = asInt(att['thread_id']) ?? payloadThread;
    final id = asInt(att['id'] ?? att['attachment_id']);
    return {
      ...att,
      if (id != null) 'id': id,
      if (tid != null) 'thread_id': tid,
    };
  }

  if (kind == 'photo_batch_uploaded' ||
      kind == 'child_milestone' ||
      payload['milestone_code'] != null) {
    return atts
        .where(isImage)
        .map(normalize)
        .where((a) => a['thread_id'] != null && a['id'] != null)
        .toList();
  }

  final singleId = asInt(payload['attachment_id']);
  if (singleId != null && payloadThread != null) {
    return [
      {
        'id': singleId,
        'thread_id': payloadThread,
        'file_url': payload['file_url'],
        'filename': payload['filename'],
        'thumbnail_url': payload['thumbnail_url'],
        'url': payload['url'],
      },
    ];
  }

  if (kind == 'message_sent') {
    return atts
        .where(isImage)
        .map(normalize)
        .where((a) => a['thread_id'] != null && a['id'] != null)
        .toList();
  }

  // Fallback: any image attachment on the event.
  final fromAtts = atts
      .where(isImage)
      .map(normalize)
      .where((a) => a['thread_id'] != null && a['id'] != null)
      .toList();
  if (fromAtts.isNotEmpty) return fromAtts;

  // Last resort: URL-only gallery fields.
  final url = galleryAttachmentUrl(payload);
  if (url.isNotEmpty && payloadThread != null && singleId != null) {
    return [
      {
        'id': singleId,
        'thread_id': payloadThread,
        'file_url': url,
      },
    ];
  }
  return const [];
}
