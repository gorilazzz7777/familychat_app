import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/chat_conversation_screen.dart';
import '../../members/presentation/member_profile_screen.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';
import '../../calendar/presentation/calendar_screen.dart';
import 'widgets/feed_event_card.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final List<Map<String, dynamic>> _events = [];
  final ScrollController _scrollController = ScrollController();
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
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

  void _onScroll() {
    if (_loadingMore || _loading) return;
    if (_events.length >= _total) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _offset = 0;
      });
    }
    try {
      final data = await ref.read(familychatRepositoryProvider).familyFeed(
            offset: 0,
            limit: _pageSize,
          );
      if (!mounted) return;
      setState(() {
        _events
          ..clear()
          ..addAll((data['events'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>());
        _total = data['total'] is int ? data['total'] as int : int.tryParse('${data['total']}') ?? 0;
        _offset = _events.length;
        _loading = false;
      });
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

  Future<void> _openSource(Map<String, dynamic> event) async {
    final kind = event['kind']?.toString() ?? '';
    final payload = (event['payload'] as Map<String, dynamic>?) ?? {};
    final status = await ref.read(familychatRepositoryProvider).status();
    final currentUserId = status['user_id'] is int ? status['user_id'] as int : null;
    if (currentUserId == null) return;

    switch (kind) {
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
              kind: 'family',
            ),
          ),
        );
      case 'photo_uploaded':
      case 'photo_added_to_album':
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
      case 'member_joined':
      case 'profile_updated':
        final userId = payload['user_id'];
        if (userId is! int) return;
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => MemberProfileScreen(userId: userId),
          ),
        );
      case 'calendar_event':
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const CalendarScreen()),
        );
      default:
        break;
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
            FilledButton(onPressed: () => _load(reset: true), child: const Text('Повторить')),
          ],
        ),
      );
    }
    if (_events.isEmpty) {
      return const Center(child: Text('Пока нет событий в ленте'));
    }

    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _events.length + (_loadingMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= _events.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final event = _events[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FeedEventCard(
              event: event,
              onOpenSource: () => _openSource(event),
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
          );
        },
      ),
    );
  }
}
