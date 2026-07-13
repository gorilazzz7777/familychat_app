import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../profile/presentation/media_engagement_sheet.dart';
import 'feed_event_date_format.dart';

class FeedEventActionBar extends ConsumerStatefulWidget {
  const FeedEventActionBar({
    super.key,
    this.attachmentId,
    required this.createdAt,
    required this.onNavigate,
    this.navigateTooltip = 'Перейти',
  });

  final int? attachmentId;
  final DateTime? createdAt;
  final VoidCallback onNavigate;
  final String navigateTooltip;

  @override
  ConsumerState<FeedEventActionBar> createState() => _FeedEventActionBarState();
}

class _FeedEventActionBarState extends ConsumerState<FeedEventActionBar> {
  bool _loading = false;
  bool _likeBusy = false;
  int _likesCount = 0;
  int _commentsCount = 0;
  bool _likedByMe = false;

  int? get _attachmentId => widget.attachmentId;

  @override
  void initState() {
    super.initState();
    _loadEngagement();
  }

  @override
  void didUpdateWidget(covariant FeedEventActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId) {
      _loadEngagement();
    }
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  Future<void> _loadEngagement() async {
    final attachmentId = _attachmentId;
    if (attachmentId == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _likesCount = 0;
          _commentsCount = 0;
          _likedByMe = false;
        });
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).mediaEngagement(attachmentId);
      if (!mounted) return;
      setState(() {
        _likesCount = _asInt(data['likes_count']);
        _commentsCount = _asInt(data['comments_count']);
        _likedByMe = data['liked_by_me'] == true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleLike() async {
    final attachmentId = _attachmentId;
    if (attachmentId == null || _likeBusy) return;
    final wasLiked = _likedByMe;
    final prevCount = _likesCount;
    setState(() {
      _likeBusy = true;
      _likedByMe = !wasLiked;
      _likesCount = wasLiked ? (_likesCount > 0 ? _likesCount - 1 : 0) : _likesCount + 1;
    });
    try {
      final data = await ref.read(familychatRepositoryProvider).toggleMediaLike(attachmentId);
      if (!mounted) return;
      setState(() {
        _likesCount = _asInt(data['likes_count']);
        _likedByMe = data['liked_by_me'] == true;
        _likeBusy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _likedByMe = wasLiked;
        _likesCount = prevCount;
        _likeBusy = false;
      });
    }
  }

  Future<void> _openComments() async {
    final attachmentId = _attachmentId;
    if (attachmentId == null) return;
    await MediaEngagementSheet.show(
      context,
      attachmentId: attachmentId,
      commentsOnly: true,
      focusComment: true,
    );
    if (!mounted) return;
    await _loadEngagement();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasMedia = _attachmentId != null;
    final dateText = widget.createdAt != null
        ? formatFeedEventDate(widget.createdAt!)
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          if (hasMedia) ...[
            IconButton(
              tooltip: _likedByMe ? 'Убрать лайк' : 'Лайк',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: _likeBusy || _loading ? null : _toggleLike,
              icon: Icon(
                _likedByMe ? Icons.favorite : Icons.favorite_border,
                size: 24,
                color: _likedByMe ? Colors.red : cs.onSurfaceVariant,
              ),
            ),
            if (_likesCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '$_likesCount',
                  style: theme.textTheme.labelLarge,
                ),
              ),
            IconButton(
              tooltip: 'Комментарии',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: _loading ? null : _openComments,
              icon: Icon(Icons.chat_bubble_outline, size: 22, color: cs.onSurfaceVariant),
            ),
            if (_commentsCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '$_commentsCount',
                  style: theme.textTheme.labelLarge,
                ),
              ),
          ],
          IconButton(
            tooltip: widget.navigateTooltip,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: widget.onNavigate,
            icon: Icon(Icons.open_in_new, size: 22, color: cs.primary),
          ),
          const Spacer(),
          if (dateText.isNotEmpty)
            Text(
              dateText,
              style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
