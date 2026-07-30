import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_compose_input.dart';
import '../../feed/presentation/widgets/feed_reactions.dart';
import 'widgets/chat_avatar.dart';

/// Реакции и комментарии прямо в ленте / под фото без bottom sheet.
class MediaEngagementInline extends ConsumerStatefulWidget {
  const MediaEngagementInline({
    super.key,
    required this.attachmentId,
    this.maxComments,
    this.dense = false,
    this.onDarkBackground = false,
  });

  final int attachmentId;
  final int? maxComments;
  final bool dense;
  final bool onDarkBackground;

  @override
  ConsumerState<MediaEngagementInline> createState() => _MediaEngagementInlineState();
}

class _MediaEngagementInlineState extends ConsumerState<MediaEngagementInline> {
  final _commentController = TextEditingController();
  bool _loading = true;
  bool _sending = false;
  bool _reactBusy = false;
  List<Map<String, dynamic>> _reactions = const [];
  List<Map<String, dynamic>> _comments = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).mediaEngagement(widget.attachmentId);
      if (!mounted) return;
      setState(() {
        _reactions = parseMediaReactions(data['reactions']);
        _comments = (data['comments'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _visibleComments {
    final max = widget.maxComments;
    if (max == null || _comments.length <= max) return _comments;
    return _comments.sublist(_comments.length - max);
  }

  Future<void> _toggleReaction(String emoji) async {
    if (_reactBusy || emoji.trim().isEmpty) return;
    setState(() => _reactBusy = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).toggleMediaReaction(
            widget.attachmentId,
            emoji: emoji,
          );
      if (!mounted) return;
      setState(() {
        _reactions = parseMediaReactions(data['reactions']);
        _reactBusy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _reactBusy = false);
    }
  }

  Future<void> _openPicker() async {
    final emoji = await showFeedReactionPicker(context);
    if (emoji == null || emoji.isEmpty || !mounted) return;
    await _toggleReaction(emoji);
  }

  Future<void> _sendComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final comment = await ref.read(familychatRepositoryProvider).addMediaComment(
            widget.attachmentId,
            body,
          );
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, comment];
        _commentController.clear();
        _sending = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final onDark = widget.onDarkBackground;
    final textColor = onDark ? Colors.white : cs.onSurface;
    final hintColor = onDark ? Colors.white54 : cs.onSurfaceVariant;
    final sendColor = onDark ? Colors.white : cs.primary;

    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FeedReactionsRow(
            reactions: _reactions,
            onReactionTap: _reactBusy ? null : _toggleReaction,
            onAddPressed: _reactBusy ? null : _openPicker,
          ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: onDark ? Colors.white54 : null,
                backgroundColor: onDark ? Colors.white24 : null,
              ),
            )
          else if (_visibleComments.isNotEmpty) ...[
            const SizedBox(height: 4),
            ..._visibleComments.map(
              (c) => _CommentRow(comment: c, textColor: textColor),
            ),
          ],
          const SizedBox(height: 8),
          FamilyComposeInput(
            controller: _commentController,
            hintText: 'Комментарий...',
            maxLines: 3,
            textInputAction: TextInputAction.send,
            onSend: _sending ? null : _sendComment,
            sending: _sending,
            fillColor: onDark ? Colors.white.withValues(alpha: 0.12) : null,
            borderColor: onDark ? Colors.white38 : null,
            textColor: onDark ? textColor : null,
            hintColor: onDark ? hintColor : null,
            sendIconColor: onDark ? sendColor : null,
          ),
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment, this.textColor});

  final Map<String, dynamic> comment;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final author = (comment['author'] as Map<String, dynamic>?) ?? {};
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChatAvatar(
            name: author['name']?.toString() ?? '?',
            avatarUrl: author['avatar_url']?.toString(),
            radius: 14,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  author['name']?.toString() ?? '',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                Text(
                  comment['body']?.toString() ?? '',
                  style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}