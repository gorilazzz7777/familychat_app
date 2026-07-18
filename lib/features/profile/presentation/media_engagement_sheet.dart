import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_compose_input.dart';
import 'widgets/chat_avatar.dart';

class MediaEngagementSheet extends ConsumerStatefulWidget {
  const MediaEngagementSheet({
    super.key,
    required this.attachmentId,
    this.focusComment = false,
    this.commentsOnly = false,
  });

  final int attachmentId;
  final bool focusComment;
  final bool commentsOnly;

  static Future<void> show(
    BuildContext context, {
    required int attachmentId,
    bool focusComment = false,
    bool commentsOnly = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: MediaEngagementSheet(
          attachmentId: attachmentId,
          focusComment: focusComment,
          commentsOnly: commentsOnly,
        ),
      ),
    );
  }

  @override
  ConsumerState<MediaEngagementSheet> createState() => _MediaEngagementSheetState();
}

class _MediaEngagementSheetState extends ConsumerState<MediaEngagementSheet> {
  final _commentController = TextEditingController();
  final _commentFocus = FocusNode();
  bool _loading = true;
  bool _sending = false;
  int _likesCount = 0;
  int _commentsCount = 0;
  bool _likedByMe = false;
  List<Map<String, dynamic>> _comments = [];

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.focusComment) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _commentFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).mediaEngagement(widget.attachmentId);
      if (!mounted) return;
      setState(() {
        _likesCount = data['likes_count'] is int ? data['likes_count'] as int : int.tryParse('${data['likes_count']}') ?? 0;
        _commentsCount = data['comments_count'] is int ? data['comments_count'] as int : int.tryParse('${data['comments_count']}') ?? 0;
        _likedByMe = data['liked_by_me'] == true;
        _comments = (data['comments'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleLike() async {
    try {
      final data = await ref.read(familychatRepositoryProvider).toggleMediaLike(widget.attachmentId);
      if (!mounted) return;
      setState(() {
        _likesCount = data['likes_count'] is int ? data['likes_count'] as int : int.tryParse('${data['likes_count']}') ?? 0;
        _likedByMe = data['liked_by_me'] == true;
      });
    } catch (_) {}
  }

  Future<void> _sendComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final comment = await ref.read(familychatRepositoryProvider).addMediaComment(widget.attachmentId, body);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, comment];
        _commentsCount += 1;
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
    final commentsOnly = widget.commentsOnly;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.55,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Text(
                  'Комментарии',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (!commentsOnly) ...[
                  IconButton(
                    onPressed: _toggleLike,
                    icon: Icon(_likedByMe ? Icons.favorite : Icons.favorite_border),
                    color: _likedByMe ? Colors.red : null,
                  ),
                  Text('$_likesCount'),
                  const SizedBox(width: 16),
                ],
                if (!commentsOnly) ...[
                  const Icon(Icons.chat_bubble_outline, size: 20),
                  const SizedBox(width: 6),
                ],
                if (!commentsOnly) Text('$_commentsCount'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const DeferredPlaceholder(
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _comments.isEmpty
                    ? Center(
                        child: Text(
                          'Пока нет комментариев',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _comments.length,
                    itemBuilder: (_, i) {
                      final c = _comments[i];
                      final author = (c['author'] as Map<String, dynamic>?) ?? {};
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ChatAvatar(
                              name: author['name']?.toString() ?? '?',
                                avatarUrl: author['avatar_url']?.toString(),
                              radius: 16,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(author['name']?.toString() ?? '', style: Theme.of(context).textTheme.labelLarge),
                                  const SizedBox(height: 2),
                                  Text(c['body']?.toString() ?? ''),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: FamilyComposeInput(
                controller: _commentController,
                focusNode: _commentFocus,
                hintText: 'Комментарий...',
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSend: _sending ? null : _sendComment,
                sending: _sending,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
