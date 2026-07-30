import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/rustore_review_prompt_service.dart';
import '../../../profile/presentation/media_engagement_sheet.dart';
import 'feed_event_date_format.dart';
import 'feed_reactions.dart';

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
  bool _reactBusy = false;
  int _commentsCount = 0;
  List<Map<String, dynamic>> _reactions = const [];

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
          _commentsCount = 0;
          _reactions = const [];
        });
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final data =
          await ref.read(familychatRepositoryProvider).mediaEngagement(attachmentId);
      if (!mounted) return;
      setState(() {
        _commentsCount = _asInt(data['comments_count']);
        _reactions = parseMediaReactions(data['reactions']);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  bool get _hasMyReaction => mediaReactionsHasMine(_reactions);

  int get _reactionsTotal => mediaReactionsTotalCount(_reactions);

  Future<void> _toggleReaction(String emoji) async {
    final attachmentId = _attachmentId;
    if (attachmentId == null || _reactBusy || emoji.trim().isEmpty) return;
    final hadMine = _hasMyReaction;
    setState(() => _reactBusy = true);
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .toggleMediaReaction(attachmentId, emoji: emoji);
      if (!mounted) return;
      final nextReactions = parseMediaReactions(data['reactions']);
      setState(() {
        _commentsCount = _asInt(data['comments_count']);
        _reactions = nextReactions;
        _reactBusy = false;
      });
      if (!hadMine && mediaReactionsHasMine(nextReactions) && mounted) {
        unawaited(
          RuStoreReviewPromptService.onFirstFeedLike(
            context,
            repository: ref.read(familychatRepositoryProvider),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _reactBusy = false);
    }
  }

  Future<void> _openReactionSheet() async {
    final emoji = await showFeedReactionPicker(context);
    if (emoji == null || emoji.isEmpty || !mounted) return;
    await _toggleReaction(emoji);
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
    final reacted = _hasMyReaction;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasMedia && _reactions.isNotEmpty) ...[
            FeedReactionsRow(
              reactions: _reactions,
              onReactionTap: _reactBusy || _loading ? null : _toggleReaction,
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: [
              if (hasMedia) ...[
                IconButton(
                  tooltip: 'Реакция',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: _reactBusy || _loading ? null : _openReactionSheet,
                  icon: Icon(
                    reacted ? Icons.favorite : Icons.favorite_border,
                    size: 24,
                    color: reacted ? Colors.red : cs.onSurfaceVariant,
                  ),
                ),
                if (_reactionsTotal > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '$_reactionsTotal',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                IconButton(
                  tooltip: 'Комментарии',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: _loading ? null : _openComments,
                  icon: Icon(
                    Icons.chat_bubble_outline,
                    size: 22,
                    color: cs.onSurfaceVariant,
                  ),
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
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
