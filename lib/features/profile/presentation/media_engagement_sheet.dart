import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_compose_input.dart';
import '../../feed/presentation/widgets/feed_reactions.dart';
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
  bool _reactBusy = false;
  int _commentsCount = 0;
  List<Map<String, dynamic>> _reactions = const [];
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

  int _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).mediaEngagement(widget.attachmentId);
      if (!mounted) return;
      setState(() {
        _commentsCount = _asInt(data['comments_count']);
        _reactions = parseMediaReactions(data['reactions']);
        _comments = (data['comments'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
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
        _commentsCount = _asInt(data['comments_count']);
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
                  '\u041A\u043E\u043C\u043C\u0435\u043D\u0442\u0430\u0440\u0438\u0438',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (!commentsOnly) ...[
                  const Icon(Icons.chat_bubble_outline, size: 20),
                  const SizedBox(width: 6),
                  Text('$_commentsCount'),
                ],
              ],
            ),
          ),
          if (!commentsOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: FeedReactionsRow(
                reactions: _reactions,
                onReactionTap: _reactBusy ? null : _toggleReaction,
                onAddPressed: _reactBusy ? null : _openPicker,
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _comments.isEmpty
                    ? Center(
                        child: Text(
                          '\u041F\u043E\u043A\u0430 \u043D\u0435\u0442 \u043A\u043E\u043C\u043C\u0435\u043D\u0442\u0430\u0440\u0438\u0435\u0432',
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
                hintText: '\u041A\u043E\u043C\u043C\u0435\u043D\u0442\u0430\u0440\u0438\u0439...',
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