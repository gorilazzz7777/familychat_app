import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/chat_conversation_screen.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';
import '../../profile/presentation/profile_gallery_album_screen.dart';
import '../../calendar/presentation/calendar_screen.dart';
import 'widgets/feed_event_card.dart';
import 'widgets/feed_people_filter.dart';

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
  int _offset = 0;
  int _total = 0;
  static const _pageSize = 30;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Обновить ленту (например при возврате на вкладку или после отправки из «Поделиться»).
  Future<void> refresh({bool silent = false}) => _load(reset: true, silent: silent);

  void _onScroll() {
    if (_loadingMore || _loading) return;
    if (_events.length >= _total) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
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
      final created = DateTime.tryParse(_events[i]['created_at']?.toString() ?? '');
      if (created != null && !created.isAfter(lastRead)) return i;
    }
    return null;
  }

  bool get _hasNewEvents {
    if (_events.isEmpty) return false;
    if (_lastReadDateTime == null) return true;
    return _events.any((e) => e['is_new'] == true);
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
    } catch (_) {}
  }

  Future<void> _load({bool reset = false, bool silent = false}) async {
    if (reset) {
      final showSpinner = !silent || _events.isEmpty;
      setState(() {
        if (showSpinner) _loading = true;
        _error = null;
        _offset = 0;
      });
    }
    try {
      final data = await ref.read(familychatRepositoryProvider).familyFeed(
            offset: 0,
            limit: _pageSize,
            personUserId: _personUserId,
          );
      if (!mounted) return;
      setState(() {
        _events
          ..clear()
          ..addAll((data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>());
        _total = data['total'] is int ? data['total'] as int : int.tryParse('${data['total']}') ?? 0;
        _offset = _events.length;
        _lastReadAt = data['last_read_at']?.toString();
        _filterPeople =
            (data['filter_people'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
      if (_hasNewEvents) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (mounted) await _markFeedRead();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _events.length >= _total) return;
    setState(() => _loadingMore = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).familyFeed(
            offset: _offset,
            limit: _pageSize,
            personUserId: _personUserId,
          );
      if (!mounted) return;
      setState(() {
        _events.addAll((data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>());
        _offset = _events.length;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
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

  List<Widget> _buildFeedItems() {
    final items = <Widget>[];
    final firstSeen = _firstSeenIndex;

    if (_hasNewEvents) {
      items.add(const FeedSectionDivider(label: 'Новые'));
    } else if (_events.isNotEmpty) {
      items.add(const FeedSectionDivider(label: 'Просмотрено'));
    }

    for (var i = 0; i < _events.length; i++) {
      if (firstSeen != null && firstSeen > 0 && i == firstSeen) {
        items.add(const FeedSectionDivider(label: 'Просмотрено'));
      }
      final event = _events[i];
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FeedEventCard(
            event: event,
            onOpenSource: () => _openSource(event),
            onOpenPhotoBatch: (batchEvent, {initialIndex = 0}) =>
                _openPhotoBatch(batchEvent, initialIndex: initialIndex),
            onOpenMedia: (photo) async {
              final status = await ref.read(familychatRepositoryProvider).status();
              final currentUserId = status['user_id'] is int ? status['user_id'] as int : null;
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

    if (_loadingMore) {
      items.add(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return items;
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
            FilledButton(onPressed: () => _load(reset: true), child: const Text('Повторить')),
          ],
        ),
      );
    }

    return Column(
      children: [
        FeedPeopleFilterBar(
          people: _filterPeople,
          selectedUserId: _personUserId,
          onSelected: (userId) async {
            setState(() => _personUserId = userId);
            await _load(reset: true);
          },
        ),
        Expanded(
          child: _events.isEmpty
              ? const Center(child: Text('Пока нет событий в ленте'))
              : RefreshIndicator(
                  onRefresh: () => _load(reset: true),
                  child: ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    children: _buildFeedItems(),
                  ),
                ),
        ),
      ],
    );
  }
}
