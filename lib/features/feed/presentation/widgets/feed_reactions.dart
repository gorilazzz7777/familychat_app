import 'package:flutter/material.dart';
import 'package:gorila_chat/gorila_chat.dart';

List<Map<String, dynamic>> parseMediaReactions(dynamic raw) {
  if (raw is! List) return const [];
  final result = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final emoji = item['emoji']?.toString() ?? '';
    if (emoji.isEmpty) continue;
    final userIds = <int>[];
    final rawIds = item['user_ids'];
    if (rawIds is List) {
      for (final e in rawIds) {
        final id = e is int ? e : int.tryParse('$e');
        if (id != null) userIds.add(id);
      }
    }
    final count = item['count'] is int
        ? item['count'] as int
        : int.tryParse('${item['count']}') ?? userIds.length;
    result.add({
      'emoji': emoji,
      'count': count,
      'user_ids': userIds,
      'reacted_by_me': item['reacted_by_me'] == true,
    });
  }
  return result;
}

int mediaReactionsTotalCount(List<Map<String, dynamic>> reactions) {
  var total = 0;
  for (final reaction in reactions) {
    final count = reaction['count'];
    if (count is int) {
      total += count;
    } else {
      total += int.tryParse('$count') ?? 0;
    }
  }
  return total;
}

bool mediaReactionsHasMine(List<Map<String, dynamic>> reactions) =>
    reactions.any((r) => r['reacted_by_me'] == true);

class FeedReactionsRow extends StatelessWidget {
  const FeedReactionsRow({
    super.key,
    required this.reactions,
    required this.onReactionTap,
    this.onAddPressed,
  });

  final List<Map<String, dynamic>> reactions;
  final void Function(String emoji)? onReactionTap;
  final VoidCallback? onAddPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (reactions.isEmpty && onAddPressed == null) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final reaction in reactions)
          _ReactionChip(
            emoji: reaction['emoji']?.toString() ?? '',
            count: reaction['count'] is int
                ? reaction['count'] as int
                : int.tryParse('${reaction['count']}') ?? 0,
            reactedByMe: reaction['reacted_by_me'] == true,
            onTap: onReactionTap,
            theme: theme,
          ),
        if (onAddPressed != null)
          InkWell(
            onTap: onAddPressed,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              child: Icon(
                Icons.add_reaction_outlined,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
    required this.theme,
    this.onTap,
  });

  final String emoji;
  final int count;
  final bool reactedByMe;
  final ThemeData theme;
  final void Function(String emoji)? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = reactedByMe
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final border = reactedByMe
        ? theme.colorScheme.primary.withValues(alpha: 0.55)
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.55);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(emoji),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border, width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              if (count > 0) ...[
                const SizedBox(width: 3),
                Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Шторка реакций как в Family Chat: быстрые эмодзи + полный picker, без пунктов меню.
Future<String?> showFeedReactionPicker(BuildContext context) async {
  final result = await ChatMessageActionsSheet.show(
    context,
    showReactions: true,
    canReply: false,
    canEdit: false,
    canCopy: false,
    canForward: false,
    canSelect: false,
    canPin: false,
    canSpeak: false,
    canDeleteForEveryone: false,
    canDeleteForMe: false,
  );
  final emoji = result?.reactionEmoji?.trim();
  if (emoji == null || emoji.isEmpty) return null;
  return emoji;
}
