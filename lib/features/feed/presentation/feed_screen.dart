import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/offline_ui.dart';
import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/media/media_incoming_sync.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../chat/presentation/chat_conversation_screen.dart';
import '../../members/presentation/child_milestone_view_screen.dart';
import '../../members/presentation/child_profile_screen.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';
import '../../profile/presentation/profile_gallery_album_screen.dart';
import '../../calendar/presentation/birthday_detail_screen.dart';
import '../../calendar/presentation/calendar_screen.dart';
import '../../chat/data/chat_offline_sync.dart';
import 'feed_jank_log.dart';
import 'feed_media_prefetch.dart';
import 'feed_scroll_busy.dart';
import 'widgets/feed_event_card.dart';
import 'widgets/feed_event_media_block.dart';
import 'widgets/feed_people_filter.dart';
import 'widgets/feed_people_list_sheet.dart';

bool _isVisibleFeedEvent(Map<String, dynamic> event) {
  final kind = event['kind']?.toString();
  return kind != 'profile_updated' &&
      kind != 'message_sent' &&
      kind != 'media_liked';
}

List<Map<String, dynamic>> _visibleFeedEvents(
  Iterable<Map<String, dynamic>> events,
) {
  final list = events.where(_isVisibleFeedEvent).toList();
  for (final event in list) {
    MediaLocalIndex.hydrateFeedEvent(event);
    final payload = event['payload'];
    if (payload is Map) {
      final atts = payload['attachments'];
      if (atts is List) {
        for (final item in atts) {
          if (item is Map<String, dynamic>) {
            FeedEventMediaBlock.seedCachedAspects([item]);
          } else if (item is Map) {
            final live = Map<String, dynamic>.from(item);
            FeedEventMediaBlock.seedCachedAspects([live]);
            item['aspect_ratio'] = live['aspect_ratio'];
          }
        }
      }
    }
  }
  unawaited(MediaIncomingSync.ensureFeedEvents(list));
  return list;
}

Future<List<Map<String, dynamic>>> _prepareFeedEvents(
  Iterable<Map<String, dynamic>> events,
) async {
  final list = _visibleFeedEvents(events);
  await hydrateFeedEventsPeople(list);
  return list;
}

bool _isAggregatedEngagementEvent(Map<String, dynamic> event) {
  final kind = event['kind']?.toString();
  if (kind != 'media_liked' && kind != 'media_commented') return false;
  final payload = (event['payload'] as Map<String, dynamic>?) ?? {};
  final flag = payload['aggregated'];
  return flag == true || flag == 'true' || flag == 1;
}

int? _eventAttachmentId(Map<String, dynamic> event) {
  final payload = (event['payload'] as Map<String, dynamic>?) ?? {};
  final raw = payload['attachment_id'];
  if (raw is int) return raw;
  return int.tryParse('$raw');
}

enum _FeedEntryKind { newDivider, seenDivider, event, loading }

class _FeedEntry {
  const _FeedEntry._(this.kind, [this.eventIndex]);

  const _FeedEntry.newDivider() : this._(_FeedEntryKind.newDivider);
  const _FeedEntry.seenDivider() : this._(_FeedEntryKind.seenDivider);
  const _FeedEntry.event(this.eventIndex) : kind = _FeedEntryKind.event;
  const _FeedEntry.loading() : this._(_FeedEntryKind.loading);

  final _FeedEntryKind kind;
  final int? eventIndex;
}

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => FeedScreenState();
}

class FeedScreenState extends ConsumerState<FeedScreen> {
  final List<Map<String, dynamic>> _events = [];
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _showScrollToTop = ValueNotifier(false);
  List<Map<String, dynamic>> _filterPeople = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  bool _lastKnownOnline = true;
  int? _personUserId;
  String? _lastReadAt;
  /// Frozen `is_new` snapshot for section dividers (Новые / Просмотрено).
  /// Rebuilt only on tab re-entry / explicit refresh — not while scrolling.
  Map<int, bool>? _frozenIsNew;
  bool _recaptureSectionsAfterLoad = false;
  bool _hasMore = false;
  int _feedLoadGen = 0;
  DateTime? _lastItemBuilderFlushAt;
  Timer? _scrollBusyClearTimer;
  VoidCallback? _pendingIdleSetState;
  bool _idleSetStateScheduled = false;
  double _lastScrollPixels = 0;
  static const _pageSize = 30;
  static const _deltaLimit = 50;
  static const _scrollToTopThreshold = 280.0;

  @override
  void initState() {
    super.initState();
    FeedJankLog.reset();
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
    _scrollController.addListener(_onScroll);
    ChatOfflineSync.instance.addListener(_onOfflineStateChanged);
    _lastKnownOnline = ChatOfflineSync.instance.isOnline;
    _loadInitial();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    FeedJankLog.clearFocus();
    _scrollBusyClearTimer?.cancel();
    FeedScrollBusy.clear();
    MediaIncomingSync.setFeedScrollBusy(false);
    FeedMediaPrefetch.clearSession();
    ChatOfflineSync.instance.removeListener(_onOfflineStateChanged);
    _scrollController.dispose();
    _showScrollToTop.dispose();
    super.dispose();
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!FeedJankLog.focused) return;
    for (final t in timings) {
      FeedJankLog.frame(t);
    }
    final now = DateTime.now();
    final last = _lastItemBuilderFlushAt;
    if (last == null || now.difference(last).inMilliseconds >= 250) {
      _lastItemBuilderFlushAt = now;
      FeedJankLog.flushItemBuilderWindow();
    }
  }

  void _onOfflineStateChanged() {
    if (!mounted) return;
    final online = ChatOfflineSync.instance.isOnline;
    final becameOnline = online && !_lastKnownOnline;
    _lastKnownOnline = online;
    if (becameOnline) {
      unawaited(refresh(silent: true));
    } else if (!online) {
      setState(() => _error = null);
    }
  }

  /// Обновить ленту (вкладка, pull-to-refresh, возврат из деталей).
  Future<void> refresh({
    bool silent = false,
    bool forceFull = false,
    bool recaptureSections = false,
  }) async {
    if (recaptureSections) _recaptureSectionsAfterLoad = true;
    if (forceFull || _events.isEmpty) {
      await _loadFull(showSpinner: !silent || _events.isEmpty);
      return;
    }
    await _syncUpdates();
    // After a fast delta, quietly refresh the first page (likes/views)
    // and backfill names on older cached posts if they still say «Участник».
    if (!silent || _events.any(feedEventNeedsPeopleRefresh)) {
      unawaited(_loadFull(showSpinner: false));
    } else if (_recaptureSectionsAfterLoad) {
      _finishSectionRecapture();
    }
  }

  /// Called when the user switches back to the Feed tab.
  Future<void> onTabEntered() async {
    await refresh(silent: true, recaptureSections: true);
  }

  void _captureSectionFreeze() {
    final map = <int, bool>{};
    for (final event in _events) {
      final id = _eventId(event);
      if (id == null) continue;
      map[id] = event['is_new'] == true;
    }
    _frozenIsNew = map;
  }

  void _finishSectionRecapture() {
    if (!_recaptureSectionsAfterLoad) {
      // First paint / no freeze yet — capture once.
      if (_frozenIsNew == null && _events.isNotEmpty) {
        _captureSectionFreeze();
      }
      return;
    }
    _recaptureSectionsAfterLoad = false;
    _captureSectionFreeze();
    if (mounted) _setStateWhenIdle(() {});
  }

  bool _isNewForSection(Map<String, dynamic> event) {
    final id = _eventId(event);
    final frozen = _frozenIsNew;
    if (id != null && frozen != null && frozen.containsKey(id)) {
      return frozen[id]!;
    }
    // Mid-session arrivals (WS / optimistic) use live flag.
    return event['is_new'] == true;
  }

  void _updateScrollToTopVisibility() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final pixels = position.pixels;
    final delta = pixels - _lastScrollPixels;
    // Ignore tiny jitter; track intentional direction.
    if (delta.abs() >= 4) {
      final deepEnough = pixels > _scrollToTopThreshold &&
          position.maxScrollExtent > _scrollToTopThreshold;
      if (delta < 0 && deepEnough) {
        // Scrolled down earlier, now moving up → show.
        _showScrollToTop.value = true;
      } else if (delta > 0) {
        // Scrolling down again → hide.
        _showScrollToTop.value = false;
      }
      _lastScrollPixels = pixels;
    }
    if (pixels <= _scrollToTopThreshold && _showScrollToTop.value) {
      _showScrollToTop.value = false;
    }
  }

  void _onScroll() {
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      final activity = pos.activity;
      final actName = activity is BallisticScrollActivity
          ? 'ballistic'
          : activity is DragScrollActivity
              ? 'drag'
              : activity is IdleScrollActivity
                  ? 'idle'
                  : activity?.runtimeType.toString() ?? 'none';
      final vel = activity is BallisticScrollActivity
          ? activity.velocity
          : 0.0;
      FeedJankLog.scroll(
        pixels: pos.pixels,
        max: pos.maxScrollExtent,
        activity: actName,
        velocity: vel,
      );
      if (activity is DragScrollActivity ||
          activity is BallisticScrollActivity) {
        FeedScrollBusy.setBusy(
          flinging: activity is BallisticScrollActivity,
        );
        MediaIncomingSync.setFeedScrollBusy(true);
        _scrollBusyClearTimer?.cancel();
        _scrollBusyClearTimer = Timer(const Duration(milliseconds: 480), () {
          if (!mounted) return;
          final act = _scrollController.hasClients
              ? _scrollController.position.activity
              : null;
          if (act is DragScrollActivity || act is BallisticScrollActivity) {
            return;
          }
          FeedScrollBusy.clear();
          MediaIncomingSync.setFeedScrollBusy(false);
          FeedJankLog.log('scroll-busy cleared');
          // After fling: decode window for the next 5 posts.
          _prefetchAroundViewport();
        });
      }
      FeedMediaPrefetch.onScroll(
        events: _events,
        pixels: pos.pixels,
      );
    }
    _updateScrollToTopVisibility();
    if (_loadingMore || _loading) return;
    if (!_hasMore) return;
    // Avoid pagination work during high-velocity fling.
    if (FeedScrollBusy.isBusy ||
        Scrollable.recommendDeferredLoadingForContext(context)) {
      return;
    }
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// Apply list mutations immediately when idle; otherwise after scroll settles.
  /// Multiple callers coalesce into a single setState to avoid BUILD storms.
  void _setStateWhenIdle(VoidCallback fn) {
    if (!mounted) return;
    final scrolling = _scrollController.hasClients &&
        _scrollController.position.isScrollingNotifier.value;
    if (!FeedScrollBusy.isBusy && !scrolling) {
      setState(fn);
      return;
    }
    FeedJankLog.log('setState deferred (scroll busy)');
    final previous = _pendingIdleSetState;
    _pendingIdleSetState = () {
      previous?.call();
      fn();
    };
    if (_idleSetStateScheduled) return;
    _idleSetStateScheduled = true;
    FeedScrollBusy.onIdle(() {
      _idleSetStateScheduled = false;
      final batch = _pendingIdleSetState;
      _pendingIdleSetState = null;
      if (!mounted || batch == null) return;
      final stillScrolling = FeedScrollBusy.isBusy ||
          (_scrollController.hasClients &&
              _scrollController.position.isScrollingNotifier.value);
      if (stillScrolling) {
        _setStateWhenIdle(batch);
        return;
      }
      // Next frame — avoid colliding with the first idle layout pass.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (FeedScrollBusy.isBusy ||
            (_scrollController.hasClients &&
                _scrollController.position.isScrollingNotifier.value)) {
          _setStateWhenIdle(batch);
          return;
        }
        setState(batch);
      });
    });
  }

  void _prefetchAroundViewport() {
    if (!mounted || _events.isEmpty) return;
    FeedMediaPrefetch.bind(
      context: context,
      repo: ref.read(familychatRepositoryProvider),
    );
    var from = 0;
    if (_scrollController.hasClients) {
      from = (_scrollController.position.pixels / FeedMediaPrefetch.approxPostHeight)
          .floor()
          .clamp(0, _events.length - 1);
    }
    FeedMediaPrefetch.ensureAround(events: _events, centerIndex: from);
  }

  Future<void> _scrollToTop() async {
    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    await refresh(silent: true, recaptureSections: true);
    if (!mounted) return;
    if (_showScrollToTop.value) {
      _showScrollToTop.value = false;
    }
  }

  int? _eventId(Map<String, dynamic> event) {
    final id = event['id'];
    if (id is int) return id;
    if (id is num) return id.toInt();
    return int.tryParse('$id');
  }

  /// Watermark для `after_id`: максимальный server id в списке.
  /// Нельзя брать id первой карточки — порядок ленты по `created_at`, а sync
  /// фильтрует по `id__gt`; иначе в delta попадают уже показанные посты и
  /// они снова prepend'ятся наверх.
  int? get _newestEventId {
    int? maxId;
    for (final event in _events) {
      if (event['_optimistic'] == true) continue;
      final id = _eventId(event);
      if (id == null || id <= 0) continue;
      if (maxId == null || id > maxId) maxId = id;
    }
    return maxId;
  }

  /// Cursor for older pages: last non-optimistic event in the list (oldest in UI).
  int? get _oldestEventId {
    for (var i = _events.length - 1; i >= 0; i--) {
      if (_events[i]['_optimistic'] == true) continue;
      final id = _eventId(_events[i]);
      if (id != null && id > 0) return id;
    }
    return null;
  }

  int? get _firstSeenIndex {
    for (var i = 0; i < _events.length; i++) {
      if (!_isNewForSection(_events[i])) return i;
    }
    return null;
  }

  bool get _startsWithNew =>
      _events.isNotEmpty && _isNewForSection(_events.first);

  bool _parseHasMore(Map<String, dynamic> data, {required int batchLength}) {
    final hasMore = data['has_more'];
    if (hasMore is bool) return hasMore;
    final total = data['total'];
    final offset = data['offset'] is int
        ? data['offset'] as int
        : int.tryParse('${data['offset']}') ?? 0;
    if (total is int) return offset + batchLength < total;
    return batchLength >= _pageSize;
  }

  void _applyMetadata(Map<String, dynamic> data, {required int batchLength}) {
    _lastReadAt = data['last_read_at']?.toString();
    _filterPeople = (data['filter_people'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    _hasMore = _parseHasMore(data, batchLength: batchLength);
  }

  void _applyFromCache(Map<String, dynamic> cached) {
    _events
      ..clear()
      ..addAll(
        _visibleFeedEvents(
          (cached['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
        ),
      );
    _hasMore = cached['has_more'] == true;
    _lastReadAt = cached['last_read_at']?.toString();
    _filterPeople = (cached['filter_people'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  String _filterPeopleFingerprint(List<Map<String, dynamic>> people) {
    return people.map((p) => '${p['user_id']}').join(',');
  }

  bool _feedEventsSameIds(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_eventId(a[i]) != _eventId(b[i])) return false;
    }
    return true;
  }

  Future<void> _persistCache() async {
    final slice = _events.length > FamilyChatLocalCache.maxCachedFeedEvents
        ? _events.sublist(0, FamilyChatLocalCache.maxCachedFeedEvents)
        : List<Map<String, dynamic>>.from(_events);
    await FamilyChatLocalCache.saveFeedSnapshot(
      personUserId: _personUserId,
      data: {
        'events': slice,
        'has_more': _hasMore,
        'last_read_at': _lastReadAt,
        'filter_people': _filterPeople,
      },
    );
  }

  /// Возвращает true, если список событий изменился.
  bool _prependUnique(List<Map<String, dynamic>> incoming) {
    if (incoming.isEmpty) return false;
    var changed = false;
    for (final event in incoming) {
      if (!_isAggregatedEngagementEvent(event)) continue;
      final kind = event['kind']?.toString();
      final attachmentId = _eventAttachmentId(event);
      if (kind == null || attachmentId == null) continue;
      final before = _events.length;
      _events.removeWhere((existing) {
        if (!_isAggregatedEngagementEvent(existing)) return false;
        if (existing['kind']?.toString() != kind) return false;
        return _eventAttachmentId(existing) == attachmentId;
      });
      if (_events.length != before) changed = true;
    }
    // Убираем только optimistic с тем же batch_id, что у реального поста.
    final incomingBatchIds = <String>{};
    for (final e in incoming) {
      if (e['_optimistic'] == true) continue;
      if (e['kind']?.toString() != 'photo_batch_uploaded') continue;
      final batchId = _eventBatchId(e);
      if (batchId != null && batchId.isNotEmpty) incomingBatchIds.add(batchId);
    }
    if (incomingBatchIds.isNotEmpty) {
      final before = _events.length;
      _events.removeWhere((existing) {
        if (existing['_optimistic'] != true) return false;
        final batchId = _eventBatchId(existing);
        return batchId != null && incomingBatchIds.contains(batchId);
      });
      if (_events.length != before) changed = true;
    }
    final ids = _events.map(_eventId).whereType<int>().toSet();
    final fresh = _visibleFeedEvents(incoming.where((event) {
      final id = _eventId(event);
      return id != null && !ids.contains(id);
    }));
    if (fresh.isEmpty) return changed;
    _events.insertAll(0, fresh);
    return true;
  }

  String? _eventBatchId(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is! Map) return null;
    final raw = payload['batch_id']?.toString().trim() ?? '';
    return raw.isEmpty ? null : raw;
  }

  /// Подставляет серверный event вместо optimistic (по batch_id) или prepend.
  void upsertServerFeedEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final prepared = _visibleFeedEvents([event]);
    if (prepared.isEmpty) return;
    final server = Map<String, dynamic>.from(prepared.first);
    server.remove('_optimistic');
    final batchId = _eventBatchId(server);
    final serverId = _eventId(server);
    setState(() {
      _events.removeWhere((existing) {
        if (existing['_optimistic'] == true) {
          final existingBatch = _eventBatchId(existing);
          return batchId != null &&
              existingBatch != null &&
              existingBatch == batchId;
        }
        final id = _eventId(existing);
        return serverId != null && id == serverId;
      });
      final ids = _events.map(_eventId).whereType<int>().toSet();
      if (serverId == null || !ids.contains(serverId)) {
        _events.insert(0, server);
      }
      _loading = false;
      _error = null;
    });
    unawaited(_persistCache());
  }

  void prependOptimisticEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final batchId = _eventBatchId(event);
    setState(() {
      _events.removeWhere((e) {
        if (e['_optimistic'] != true) return false;
        if (batchId == null) return true;
        return _eventBatchId(e) == batchId;
      });
      _events.insert(0, event);
      _loading = false;
      _error = null;
    });
    unawaited(_persistCache());
  }

  Future<void> _showCachedSnapshot(Map<String, dynamic> cached) async {
    _applyFromCache(cached);
    await hydrateFeedEventsPeople(_events);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = null;
    });
    _finishSectionRecapture();
    unawaited(_persistCache());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchAroundViewport();
    });
  }

  Future<void> _loadInitial() async {
    final cached =
        await FamilyChatLocalCache.readFeedSnapshot(personUserId: _personUserId);
    if (cached != null && mounted) {
      await _showCachedSnapshot(cached);
      await _syncUpdates();
      // Prefer server is_new over cache once first network page lands.
      _recaptureSectionsAfterLoad = true;
      unawaited(_loadFull(showSpinner: false));
      return;
    }
    _recaptureSectionsAfterLoad = true;
    await _loadFull(showSpinner: true);
  }

  Future<void> _loadFull({required bool showSpinner}) async {
    final gen = ++_feedLoadGen;
    if (showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await ref.read(familychatRepositoryProvider).familyFeed(
            offset: 0,
            limit: _pageSize,
            personUserId: _personUserId,
          );
      if (!mounted || gen != _feedLoadGen) return;
      final batch = await _prepareFeedEvents(
        (data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
      );
      final newLastRead = data['last_read_at']?.toString();
      final newFilter = (data['filter_people'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final newHasMore = _parseHasMore(data, batchLength: batch.length);

      // Keep a longer cached tail only when the first page is an exact prefix.
      // If the head drifted (new posts / reordering), replace fully — otherwise
      // offset holes appear between the new head and a stale tail.
      final canKeepTail = _events.length > batch.length &&
          batch.isNotEmpty &&
          _feedEventsSameIds(_events.take(batch.length).toList(), batch);

      // Не теряем локальные серверные id новее головы ответа и unmatched optimistic.
      final batchIds = batch.map(_eventId).whereType<int>().toSet();
      final batchMaxId = batchIds.isEmpty
          ? null
          : batchIds.reduce((a, b) => a > b ? a : b);
      final keepLocal = <Map<String, dynamic>>[];
      for (final existing in _events) {
        if (existing['_optimistic'] == true) {
          final batchId = _eventBatchId(existing);
          final matched = batch.any((e) => _eventBatchId(e) == batchId);
          if (!matched) keepLocal.add(existing);
          continue;
        }
        final id = _eventId(existing);
        if (id == null || id <= 0) continue;
        if (batchIds.contains(id)) continue;
        if (batchMaxId != null && id > batchMaxId) {
          keepLocal.add(existing);
        }
      }

      if (canKeepTail) {
        _events.replaceRange(0, batch.length, batch);
        await hydrateFeedEventsPeople(_events.skip(batch.length));
      } else {
        _events
          ..clear()
          ..addAll([
            ...keepLocal,
            ...batch,
          ]);
        // keepLocal уже отсортированы сверху как «новее»; batch — первая страница.
        // Убедимся, что нет дублей id.
        final seen = <int>{};
        _events.retainWhere((e) {
          final id = _eventId(e);
          if (id == null) return e['_optimistic'] == true;
          if (seen.contains(id)) return false;
          seen.add(id);
          return true;
        });
      }
      if (!mounted || gen != _feedLoadGen) return;

      void apply() {
        _lastReadAt = newLastRead;
        if (newFilter.isNotEmpty) {
          _filterPeople = newFilter;
        }
        _hasMore = newHasMore;
        _loading = false;
        _error = null;
      }

      if (showSpinner) {
        setState(apply);
      } else {
        // Silent refresh mid-fling was causing 200–300ms full-list frames.
        _setStateWhenIdle(apply);
      }
      unawaited(_persistCache());
      _finishSectionRecapture();
      if (canKeepTail) {
        unawaited(
          _reloadStaleCachedEvents(gen: gen, firstPageLength: batch.length),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateScrollToTopVisibility();
        if (mounted) _prefetchAroundViewport();
      });
    } catch (e) {
      if (!mounted || gen != _feedLoadGen) return;
      setState(() {
        _loading = false;
        _error = _events.isEmpty
            ? OfflineUi.loadErrorMessage(e, fallback: 'Не удалось загрузить ленту')
            : null;
      });
    }
  }

  /// Re-fetch older cached pages so reaction/view names are not leftover «Участник».
  Future<void> _reloadStaleCachedEvents({
    required int gen,
    required int firstPageLength,
  }) async {
    if (!mounted || gen != _feedLoadGen) return;
    if (firstPageLength <= 0 || _events.length <= firstPageLength) return;
    if (_events.every((event) => !feedEventNeedsPeopleRefresh(event))) return;
    if (!ChatOfflineSync.instance.isOnline) return;

    var cursor = _eventId(_events[firstPageLength - 1]);
    if (cursor == null) return;
    final oldest = _oldestEventId;
    var changed = false;
    for (var page = 0; page < 5; page++) {
      if (!mounted || gen != _feedLoadGen) return;
      try {
        final data = await ref.read(familychatRepositoryProvider).familyFeed(
              beforeId: cursor,
              limit: _pageSize,
              personUserId: _personUserId,
            );
        if (!mounted || gen != _feedLoadGen) return;
        final batch = await _prepareFeedEvents(
          (data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
        );
        if (batch.isEmpty) break;
        final byId = <int, Map<String, dynamic>>{};
        for (final event in batch) {
          final id = _eventId(event);
          if (id != null) byId[id] = event;
        }
        for (var i = 0; i < _events.length; i++) {
          final id = _eventId(_events[i]);
          final fresh = id == null ? null : byId[id];
          if (fresh == null) continue;
          _events[i] = fresh;
          changed = true;
        }
        final lastId = _eventId(batch.last);
        if (lastId == null) break;
        cursor = lastId;
        if (oldest != null && cursor <= oldest) break;
        if (!_parseHasMore(data, batchLength: batch.length)) break;
      } catch (_) {
        break;
      }
    }
    if (!mounted || gen != _feedLoadGen || !changed) return;
    _setStateWhenIdle(() {});
    unawaited(_persistCache());
  }

  Future<void> _syncUpdates() async {
    final afterId = _newestEventId;
    try {
      final data = await ref.read(familychatRepositoryProvider).familyFeed(
            afterId: afterId,
            limit: _deltaLimit,
            personUserId: _personUserId,
          );
      if (!mounted) return;
      final batch = await _prepareFeedEvents(
        (data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
      );
      // Большой catch-up (протухший кэш / дырка в id): prepend истории наверх
      // даёт дубли и «старые посты сверху». Безопаснее полная первая страница.
      final deltaHasMore = data['has_more'] == true;
      if (afterId != null &&
          batch.isNotEmpty &&
          (deltaHasMore || batch.length >= _deltaLimit)) {
        await _loadFull(showSpinner: false);
        return;
      }

      final newLastRead = data['last_read_at']?.toString();
      final newFilter = (data['filter_people'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final metaChanged = newLastRead != _lastReadAt ||
          (newFilter.isNotEmpty &&
              _filterPeopleFingerprint(newFilter) !=
                  _filterPeopleFingerprint(_filterPeople));

      var eventsChanged = false;
      if (afterId == null) {
        if (batch.isNotEmpty) {
          eventsChanged = !_feedEventsSameIds(_events, batch);
        }
      } else {
        // Предварительно оценим, есть ли новые id.
        final ids = _events.map(_eventId).whereType<int>().toSet();
        eventsChanged = batch.any((e) {
          final id = _eventId(e);
          return id != null && !ids.contains(id);
        });
        // Агрегированные engagement тоже могут заменить карточки.
        if (!eventsChanged) {
          eventsChanged = batch.any(_isAggregatedEngagementEvent);
        }
      }

      if (!eventsChanged &&
          !metaChanged &&
          !_loading &&
          _error == null) {
        _finishSectionRecapture();
        return;
      }

      _setStateWhenIdle(() {
        if (afterId == null) {
          if (batch.isNotEmpty && eventsChanged) {
            _events
              ..clear()
              ..addAll(batch);
          }
          _applyMetadata(data, batchLength: batch.length);
        } else {
          if (eventsChanged) {
            _prependUnique(batch);
          }
          _lastReadAt = newLastRead;
          if (newFilter.isNotEmpty) {
            _filterPeople = newFilter;
          }
        }
        _loading = false;
        _error = null;
      });
      if (eventsChanged || metaChanged) {
        unawaited(_persistCache());
      }
      _finishSectionRecapture();
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollToTopVisibility());
    } catch (e) {
      if (!mounted) return;
      if (_events.isEmpty) {
        setState(() {
          _loading = false;
          _error = OfflineUi.loadErrorMessage(
            e,
            fallback: 'Не удалось загрузить ленту',
          );
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final beforeId = _oldestEventId;
    FeedJankLog.loadMore(started: true);
    setState(() => _loadingMore = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).familyFeed(
            // Prefer stable cursor; offset falls back for older servers.
            beforeId: beforeId,
            offset: beforeId == null ? _events.length : 0,
            limit: _pageSize,
            personUserId: _personUserId,
          );
      if (!mounted) return;
      final batch = await _prepareFeedEvents(
        (data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
      );
      final existingIds = _events.map(_eventId).whereType<int>().toSet();
      final unique = <Map<String, dynamic>>[];
      for (final event in batch) {
        final id = _eventId(event);
        if (id != null && existingIds.contains(id)) continue;
        if (id != null) existingIds.add(id);
        unique.add(event);
      }
      setState(() {
        _events.addAll(unique);
        _hasMore = _parseHasMore(data, batchLength: batch.length);
        _loadingMore = false;
      });
      FeedJankLog.loadMore(started: false, added: unique.length);
      await _persistCache();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateScrollToTopVisibility();
        if (mounted) _prefetchAroundViewport();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      FeedJankLog.loadMore(started: false, added: 0);
    }
  }

  Future<void> _onPersonFilterSelected(int? userId) async {
    setState(() => _personUserId = userId);
    _recaptureSectionsAfterLoad = true;
    final cached =
        await FamilyChatLocalCache.readFeedSnapshot(personUserId: userId);
    if (cached != null && mounted) {
      await _showCachedSnapshot(cached);
      await _syncUpdates();
      _recaptureSectionsAfterLoad = true;
      if (mounted) {
        unawaited(_loadFull(showSpinner: false));
      }
      return;
    }
    await _loadFull(showSpinner: true);
  }

  Future<void> _openPhotoBatch(
    Map<String, dynamic> event, {
    int initialIndex = 0,
  }) async {
    final payload = (event['payload'] as Map<String, dynamic>?) ?? {};
    final status = await ref.read(familychatRepositoryProvider).status();
    final currentUserId = status['user_id'] is int ? status['user_id'] as int : null;
    if (currentUserId == null || !mounted) return;

    final photos = (payload['attachments'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((att) {
          final rawId = att['id'] ?? att['attachment_id'];
          final id = rawId is int ? rawId : int.tryParse('$rawId');
          final threadId = att['thread_id'] is int
              ? att['thread_id'] as int
              : int.tryParse('${att['thread_id']}');
          if (id == null || threadId == null) return null;
          return {
            ...att,
            'id': id,
            'thread_id': threadId,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();
    if (photos.isEmpty) return;

    await GalleryPhotoViewerScreen.open(
      context,
      profileUserId: currentUserId,
      photo: photos[initialIndex.clamp(0, photos.length - 1)],
      currentUserId: currentUserId,
      photos: photos,
      initialIndex: initialIndex,
    );
    if (mounted) await refresh(silent: true);
  }

  Future<void> _openSource(Map<String, dynamic> event) async {
    final kind = event['kind']?.toString() ?? '';
    final payload = (event['payload'] as Map<String, dynamic>?) ?? {};
    final actor = (event['actor'] as Map<String, dynamic>?) ?? {};
    final status = await ref.read(familychatRepositoryProvider).status();
    final currentUserId = status['user_id'] is int ? status['user_id'] as int : null;
    if (currentUserId == null) return;

    switch (kind) {
      case 'photo_batch_uploaded':
        final batchChildRaw = payload['child_id'];
        final batchChildId = batchChildRaw is int
            ? batchChildRaw
            : int.tryParse('$batchChildRaw');
        if (batchChildId != null) {
          if (!mounted) return;
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ChildProfileScreen(
                childId: batchChildId,
                initialTabIndex: 1,
              ),
            ),
          );
          if (mounted) await refresh(silent: true);
        } else {
          await _openPhotoBatch(event);
        }
      case 'message_sent':
        final threadId = payload['thread_id'];
        if (threadId is! int) return;
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ChatConversationScreen(
              threadId: threadId,
              title: payload['thread_title']?.toString() ?? 'Чат',
              defaultTitle: payload['thread_title']?.toString() ?? 'Чат',
              kind: payload['thread_kind']?.toString() ?? 'family',
            ),
          ),
        );
        if (mounted) await refresh(silent: true);
      case 'photo_added_to_album':
        final albumId = payload['album_id']?.toString();
        final ownerId = actor['user_id'];
        if (albumId == null || ownerId is! int) return;
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ProfileGalleryAlbumScreen(
              userId: ownerId,
              albumId: albumId,
              title: payload['album_title']?.toString() ?? 'Альбом',
              canManage: ownerId == currentUserId,
              isOwnGallery: ownerId == currentUserId,
            ),
          ),
        );
        if (mounted) await refresh(silent: true);
      case 'photo_uploaded':
        final childIdRaw = payload['child_id'];
        final childId = childIdRaw is int
            ? childIdRaw
            : int.tryParse('$childIdRaw');
        if (!mounted) return;
        if (childId != null) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ChildProfileScreen(
                childId: childId,
                initialTabIndex: 1,
              ),
            ),
          );
        } else {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ProfileGalleryAlbumScreen(
                userId: currentUserId,
                albumId: 'all',
                title: 'Галерея',
                isOwnGallery: true,
                isFamilyGallery: true,
              ),
            ),
          );
        }
        if (mounted) await refresh(silent: true);
      case 'media_liked':
      case 'media_commented':
        final attachmentId = payload['attachment_id'];
        final threadId = payload['thread_id'];
        if (attachmentId is! int || threadId is! int) return;
        final photo = {
          'id': attachmentId,
          'thread_id': threadId,
          'file_url': payload['file_url'],
          'filename': payload['filename'],
        };
        if (!mounted) return;
        await GalleryPhotoViewerScreen.open(
          context,
          profileUserId: currentUserId,
          photo: photo,
          currentUserId: currentUserId,
        );
        if (mounted) await refresh(silent: true);
      case 'member_joined':
      case 'profile_updated':
        final userId = payload['user_id'] ?? actor['user_id'];
        if (userId is! int) return;
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => MemberProfileScreen(userId: userId),
          ),
        );
        if (mounted) await refresh(silent: true);
      case 'calendar_event':
        final eventKind = payload['event_kind']?.toString() ?? '';
        if (eventKind == 'birthday') {
          final rawHonoreeId = payload['person_user_id'] ?? payload['user_id'];
          final honoreeId =
              rawHonoreeId is int ? rawHonoreeId : int.tryParse('$rawHonoreeId');
          if (honoreeId != null) {
            if (!mounted) return;
            await Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => BirthdayDetailScreen(
                  honoreeUserId: honoreeId,
                  initialTitle: payload['person_name']?.toString() ??
                      payload['title']?.toString() ??
                      'День рождения',
                  eventDate: payload['date']?.toString(),
                ),
              ),
            );
            if (mounted) await refresh(silent: true);
            return;
          }
        }
        if (eventKind == 'milestone') {
          final code = payload['milestone_code']?.toString() ??
              payload['code']?.toString() ??
              '';
          if (code.isNotEmpty) {
            final rawChildId = payload['child_id'];
            final childId =
                rawChildId is int ? rawChildId : int.tryParse('$rawChildId');
            if (!mounted) return;
            await Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ChildMilestoneViewScreen(
                  code: code,
                  initialTitle: payload['milestone_title']?.toString() ??
                      payload['title']?.toString(),
                  childId: childId,
                  childName: payload['child_name']?.toString(),
                ),
              ),
            );
            if (mounted) await refresh(silent: true);
            return;
          }
        }
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const CalendarScreen()),
        );
        if (mounted) await refresh(silent: true);
      default:
        break;
    }
  }

  List<_FeedEntry> _buildEntries() {
    final entries = <_FeedEntry>[];
    final firstSeen = _firstSeenIndex;

    if (_startsWithNew) {
      entries.add(const _FeedEntry.newDivider());
    } else if (_events.isNotEmpty) {
      entries.add(const _FeedEntry.seenDivider());
    }

    for (var i = 0; i < _events.length; i++) {
      if (firstSeen != null && firstSeen > 0 && i == firstSeen) {
        entries.add(const _FeedEntry.seenDivider());
      }
      entries.add(_FeedEntry.event(i));
    }

    if (_loadingMore) {
      entries.add(const _FeedEntry.loading());
    }

    return entries;
  }

  Widget _buildEntry(_FeedEntry entry) {
    FeedJankLog.itemBuilderTick();
    switch (entry.kind) {
      case _FeedEntryKind.newDivider:
        return const FeedSectionDivider(label: 'Новые');
      case _FeedEntryKind.seenDivider:
        return const FeedSectionDivider(label: 'Просмотрено');
      case _FeedEntryKind.loading:
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        );
      case _FeedEntryKind.event:
        final index = entry.eventIndex!;
        final event = _events[index];
        final eventKey = _eventId(event);
        return Padding(
          key: ValueKey(eventKey ?? 'feed_idx_$index'),
          padding: const EdgeInsets.only(bottom: 12),
          child: RepaintBoundary(
            child: FeedEventCard(
            event: event,
            onOpenSource: () => _openSource(event),
            onOpenProfile: () async {
              final payload = (event['payload'] as Map<String, dynamic>?) ?? {};
              final isBirthday = event['kind']?.toString() == 'calendar_event' &&
                  payload['event_kind']?.toString() == 'birthday';
              final isHoliday = event['kind']?.toString() == 'calendar_event' &&
                  payload['event_kind']?.toString() == 'holiday';
              if (isHoliday) return;
              final actor = (event['actor'] as Map<String, dynamic>?) ?? {};
              final rawId = isBirthday
                  ? (payload['person_user_id'] ?? actor['user_id'])
                  : actor['user_id'];
              final userId = rawId is int ? rawId : int.tryParse('$rawId');
              if (userId == null || !mounted) return;
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => MemberProfileScreen(userId: userId),
                ),
              );
              if (mounted) await refresh(silent: true);
            },
            onOpenPhotoBatch: (batchEvent, {initialIndex = 0}) =>
                _openPhotoBatch(batchEvent, initialIndex: initialIndex),
            onEngagementChanged: () => unawaited(_persistCache()),
            onDeleted: () {
              final id = _eventId(event);
              setState(() {
                _events.removeWhere((e) => _eventId(e) == id);
              });
              unawaited(_persistCache());
            },
            onOpenMedia: (photo) async {
              final status = await ref.read(familychatRepositoryProvider).status();
              final currentUserId =
                  status['user_id'] is int ? status['user_id'] as int : null;
              if (currentUserId == null || !mounted) return;
              await GalleryPhotoViewerScreen.open(
                context,
                profileUserId: currentUserId,
                photo: photo,
                currentUserId: currentUserId,
              );
            },
          ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sw = Stopwatch()..start();
    if (_loading) {
      return const DeferredPlaceholder(child: FeedListSkeleton());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _loadFull(showSpinner: true),
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }

    final entries = _buildEntries();
    sw.stop();
    FeedJankLog.build(
      ms: sw.elapsedMilliseconds,
      events: _events.length,
      rows: entries.length,
    );

    return Column(
      children: [
        FeedPeopleFilterBar(
          people: _filterPeople,
          selectedUserId: _personUserId,
          onSelected: _onPersonFilterSelected,
        ),
        Expanded(
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              if (_events.isEmpty)
                RefreshIndicator(
                  onRefresh: () => refresh(recaptureSections: true),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
                      const Center(child: Text('Пока нет событий в ленте')),
                    ],
                  ),
                )
              else
                RefreshIndicator(
                  onRefresh: () => refresh(recaptureSections: true),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    cacheExtent: 480,
                    addAutomaticKeepAlives: false,
                    itemCount: entries.length,
                    itemBuilder: (context, index) => _buildEntry(entries[index]),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                top: 10,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _showScrollToTop,
                  builder: (context, show, child) {
                    return IgnorePointer(
                      ignoring: !show,
                      child: AnimatedOpacity(
                        opacity: show ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: AnimatedSlide(
                          offset: show ? Offset.zero : const Offset(0, -0.35),
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: Center(
                    child: _FeedScrollToTopButton(onPressed: _scrollToTop),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeedScrollToTopButton extends StatelessWidget {
  const _FeedScrollToTopButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Semantics(
      button: true,
      label: 'Вверх',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(22),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: cs.surface.withValues(alpha: 0.94),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.85),
              ),
              boxShadow: [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.14),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 16, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.arrow_up,
                    size: 18,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Вверх',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
