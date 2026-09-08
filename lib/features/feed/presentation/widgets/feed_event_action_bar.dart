import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/rustore_review_prompt_service.dart';
import '../../../profile/presentation/media_engagement_sheet.dart';
import 'feed_event_date_format.dart';
import 'feed_people_list_sheet.dart';
import 'feed_reactions.dart';

class FeedEventActionBar extends ConsumerStatefulWidget {
  const FeedEventActionBar({
    super.key,
    this.attachmentId,
    required this.event,
    required this.createdAt,
    required this.onNavigate,
    this.navigateTooltip = 'Перейти',
    this.onEngagementChanged,
  });

  final int? attachmentId;
  final Map<String, dynamic> event;
  final DateTime? createdAt;
  final VoidCallback onNavigate;
  final String navigateTooltip;
  final VoidCallback? onEngagementChanged;

  @override
  ConsumerState<FeedEventActionBar> createState() => _FeedEventActionBarState();
}

class _FeedEventActionBarState extends ConsumerState<FeedEventActionBar> {
  bool _reactBusy = false;
  int _commentsCount = 0;
  List<Map<String, dynamic>> _reactions = const [];

  int? get _attachmentId => widget.attachmentId;

  @override
  void initState() {
    super.initState();
    _readStored();
  }

  @override
  void didUpdateWidget(covariant FeedEventActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_reactBusy) return;
    _readStored();
  }

  void _readStored() {
    final stored = feedEngagementFromEvent(
      widget.event,
      attachmentId: _attachmentId,
    );
    _reactions = stored.reactions;
    _commentsCount = stored.commentsCount;
  }

  void _storeLocal({
    required List<Map<String, dynamic>> reactions,
    required int commentsCount,
  }) {
    final attachmentId = _attachmentId;
    if (attachmentId != null) {
      writeFeedEngagementToEvent(
        widget.event,
        attachmentId: attachmentId,
        reactions: reactions,
        commentsCount: commentsCount,
      );
    }
    widget.onEngagementChanged?.call();
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
      final commentsCount = data['comments_count'] is int
          ? data['comments_count'] as int
          : int.tryParse('${data['comments_count']}') ?? _commentsCount;
      setState(() {
        _commentsCount = commentsCount;
        _reactions = nextReactions;
        _reactBusy = false;
      });
      _storeLocal(reactions: nextReactions, commentsCount: commentsCount);
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
    try {
      final data =
          await ref.read(familychatRepositoryProvider).mediaEngagement(attachmentId);
      if (!mounted) return;
      final nextReactions = parseMediaReactions(data['reactions']);
      final commentsCount = data['comments_count'] is int
          ? data['comments_count'] as int
          : int.tryParse('${data['comments_count']}') ?? _commentsCount;
      setState(() {
        _reactions = nextReactions;
        _commentsCount = commentsCount;
      });
      _storeLocal(reactions: nextReactions, commentsCount: commentsCount);
    } catch (_) {}
  }

  Future<void> _openReactionPeople() async {
    var people = mediaReactionPeople(_reactions);
    if (people.isEmpty) return;
    final needsNames = people.any(
      (person) =>
          feedPersonUserId(person) != null &&
          feedPersonDisplayName(person).isEmpty,
    );
    final attachmentId = _attachmentId;
    if (needsNames && attachmentId != null) {
      try {
        final data = await ref
            .read(familychatRepositoryProvider)
            .mediaEngagement(attachmentId);
        if (!mounted) return;
        final nextReactions = parseMediaReactions(data['reactions']);
        final commentsCount = data['comments_count'] is int
            ? data['comments_count'] as int
            : int.tryParse('${data['comments_count']}') ?? _commentsCount;
        setState(() {
          _reactions = nextReactions;
          _commentsCount = commentsCount;
        });
        _storeLocal(reactions: nextReactions, commentsCount: commentsCount);
        people = mediaReactionPeople(nextReactions);
      } catch (_) {}
    }
    if (!mounted || people.isEmpty) return;
    await FeedPeopleListSheet.show(
      context,
      title: 'Реакции',
      people: people,
      emptyText: 'Пока никто не поставил реакцию',
    );
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
              onReactionTap: _reactBusy ? null : _toggleReaction,
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
                  onPressed: _reactBusy ? null : _openReactionSheet,
                  icon: Icon(
                    reacted ? Icons.favorite : Icons.favorite_border,
                    size: 24,
                    color: reacted ? Colors.red : cs.onSurfaceVariant,
                  ),
                ),
                if (_reactionsTotal > 0)
                  Tooltip(
                    message: 'Кто поставил реакцию',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _openReactionPeople,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(2, 6, 8, 6),
                          child: Text(
                            '$_reactionsTotal',
                            style: feedTappableCountStyle(theme),
                          ),
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Комментарии',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: _openComments,
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
