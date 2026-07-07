import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import 'widgets/chat_avatar.dart';

/// Лайки и комментарии прямо в ленте / под фото без bottom sheet.
class MediaEngagementInline extends ConsumerStatefulWidget {
  const MediaEngagementInline({
    super.key,
    required this.attachmentId,
    this.maxComments,
    this.dense = false,
    this.onDarkBackground = false,
  });

  final int attachmentId;

  /// Если задано — показываем только последние N комментариев.
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
  bool _likeBusy = false;
  int _likesCount = 0;
  bool _likedByMe = false;
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
        _likesCount = _asInt(data['likes_count']);
        _likedByMe = data['liked_by_me'] == true;
        _comments = (data['comments'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  List<Map<String, dynamic>> get _visibleComments {
    final max = widget.maxComments;
    if (max == null || _comments.length <= max) return _comments;
    return _comments.sublist(_comments.length - max);
  }

  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    final wasLiked = _likedByMe;
    final prevCount = _likesCount;
    setState(() {
      _likeBusy = true;
      _likedByMe = !wasLiked;
      _likesCount = wasLiked ? (_likesCount > 0 ? _likesCount - 1 : 0) : _likesCount + 1;
    });
    try {
      final data = await ref.read(familychatRepositoryProvider).toggleMediaLike(widget.attachmentId);
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
    final iconColor = onDark ? Colors.white70 : cs.onSurfaceVariant;
    final sendColor = onDark ? Colors.white : cs.primary;
    final pad = widget.dense ? 0.0 : 0.0;

    return Padding(
      padding: EdgeInsets.only(top: pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: _likedByMe ? 'Убрать лайк' : 'Лайк',
                onPressed: _likeBusy ? null : _toggleLike,
                icon: Icon(
                  _likedByMe ? Icons.favorite : Icons.favorite_border,
                  size: 22,
                  color: _likedByMe ? Colors.red : iconColor,
                ),
              ),
              if (_likesCount > 0)
                Text(
                  '$_likesCount',
                  style: theme.textTheme.labelLarge?.copyWith(color: textColor),
                ),
            ],
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _commentController,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendComment(),
                  decoration: InputDecoration(
                    hintText: 'Комментарий...',
                    hintStyle: TextStyle(color: hintColor),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(color: onDark ? Colors.white38 : cs.outline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(color: onDark ? Colors.white70 : cs.primary),
                    ),
                  ),
                  style: TextStyle(color: textColor),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Отправить',
                onPressed: _sending ? null : _sendComment,
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.send, color: sendColor),
              ),
            ],
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
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
                children: [
                  TextSpan(
                    text: '${author['name']?.toString() ?? ''} ',
                    style: theme.textTheme.labelLarge?.copyWith(color: textColor),
                  ),
                  TextSpan(text: comment['body']?.toString() ?? ''),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
