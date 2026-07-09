import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/chat_conversation_screen.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';
import '../../profile/presentation/profile_gallery_album_screen.dart';
import '../../calendar/presentation/calendar_screen.dart';
import 'widgets/feed_event_card.dart';
import 'widgets/feed_people_filter.dart';

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
  List<Map<String, dynamic>> _filterPeople = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int? _personUserId;
  String? _lastReadAt;
  bool _hasMore = false;
  static const _pageSize = 30;
  static const _deltaLimit = 50;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Обновить ленту (вкладка, pull-to-refresh, возврат из деталей).
  Future<void> refresh({bool silent = false, bool forceFull = false}) async {
    if (forceFull || _events.isEmpty) {
      await _loadFull(showSpinner: !silent || _events.isEmpty);
      return;
    }
    await _syncUpdates();
  }

  void _onScroll() {
    if (_loadingMore || _loading) return;
    if (!_hasMore) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  int? _eventId(Map<String, dynamic> event) {
    final id = event['id'];
    return id is int ? id : int.tryParse('$id');
  }

  int? get _newestEventId {
    for (final event in _events) {
      final id = _eventId(event);
      if (id != null) return id;
    }
    return null;
  }

  DateTime? get _lastReadDateTime {
    final raw = _lastReadAt;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  int? get _firstSeenIndex {
    final lastRead = _lastReadDateTime;
    if (lastRead == null) return null;
    for (var i = 0; i < _events.length; i++) {
      final created =
          DateTime.tryParse(_events[i]['created_at']?.toString() ?? '');
      if (created != null && !created.isAfter(lastRead)) return i;
    }
    return null;
  }

  bool get _hasNewEvents {
    if (_events.isEmpty) return false;
    if (_lastReadDateTime == null) return true;
    return _events.any((e) => e['is_new'] == true);
  }

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
        (cached['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
      );
    _hasMore = cached['has_more'] == true;
    _lastReadAt = cached['last_read_at']?.toString();
    _filterPeople = (cached['filter_people'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
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

  void _prependUnique(List<Map<String, dynamic>> incoming) {
    if (incoming.isEmpty) return;
    final ids = _events.map(_eventId).whereType<int>().toSet();
    final fresh = incoming.where((event) {
      final id = _eventId(event);
      return id != null && !ids.contains(id);
    }).toList();
    if (fresh.isEmpty) return;
    _events.insertAll(0, fresh);
  }

  Future<void> _maybeMarkRead() async {
    if (!_hasNewEvents) return;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    await _markFeedRead();
  }

  Future<void> _markFeedRead() async {
    try {
      final data = await ref.read(familychatRepositoryProvider).markFeedRead();
      if (!mounted) return;
      setState(() {
        _lastReadAt = data['last_read_at']?.toString();
        for (final event in _events) {
          event['is_new'] = false;
        }
      });
      await _persistCache();
    } catch (_) {}
  }

  Future<void> _loadInitial() async {
    final cached =
        await FamilyChatLocalCache.readFeedSnapshot(personUserId: _personUserId);
    if (cached != null && mounted) {
      setState(() {
        _applyFromCache(cached);
        _loading = false;
        _error = null;
      });
      await _syncUpdates();
      return;
    }
    await _loadFull(showSpinner: true);
  }

  Future<void> _loadFull({required bool showSpinner}) async {
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
      if (!mounted) return;
      final batch =
          (data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _events
          ..clear()
          ..addAll(batch);
        _applyMetadata(data, batchLength: batch.length);
        _loading = false;
      });
      await _persistCache();
      await _maybeMarkRead();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
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
      final batch =
          (data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        if (afterId == null) {
          if (batch.isNotEmpty) {
            _events
              ..clear()
              ..addAll(batch);
          }
          _applyMetadata(data, batchLength: batch.length);
        } else {
          _prependUnique(batch);
          _lastReadAt = data['last_read_at']?.toString();
          _filterPeople = (data['filter_people'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
        }
        _loading = false;
        _error = null;
      });
      await _persistCache();
      await _maybeMarkRead();
    } catch (e) {
      if (!mounted) return;
      if (_events.isEmpty) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).familyFeed(
            offset: _events.length,
            limit: _pageSize,
            personUserId: _personUserId,
          );
      if (!mounted) return;
      final batch =
          (data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _events.addAll(batch);
        _hasMore = _parseHasMore(data, batchLength: batch.length);
        _loadingMore = false;
      });
      await _persistCache();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _onPersonFilterSelected(int? userId) async {
    setState(() => _personUserId = userId);
    final cached =
        await FamilyChatLocalCache.readFeedSnapshot(personUserId: userId);
    if (cached != null && mounted) {
      setState(() {
        _applyFromCache(cached);
        _loading = false;
        _error = null;
      });
      await _syncUpdates();
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
        await _openPhotoBatch(event);
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
        if (!mounted) return;
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

    if (_hasNewEvents) {
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
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FeedEventCard(
            event: event,
            onOpenSource: () => _openSource(event),
            onOpenPhotoBatch: (batchEvent, {initialIndex = 0}) =>
                _openPhotoBatch(batchEvent, initialIndex: initialIndex),
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
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
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

    return Column(
      children: [
        FeedPeopleFilterBar(
          people: _filterPeople,
          selectedUserId: _personUserId,
          onSelected: _onPersonFilterSelected,
        ),
        Expanded(
          child: _events.isEmpty
              ? RefreshIndicator(
                  onRefresh: () => refresh(forceFull: true),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
                      const Center(child: Text('Пока нет событий в ленте')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => refresh(),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: entries.length,
                    itemBuilder: (context, index) => _buildEntry(entries[index]),
                  ),
                ),
        ),
      ],
    );
  }
}
