import 'package:flutter/material.dart';

/// Быстрые реакции в ленте меню (как в Telegram).
const kChatQuickReactionEmojis = [
  '👍',
  '❤️',
  '😂',
  '😮',
  '😢',
  '🙏',
  '🔥',
  '👏',
];

List<Map<String, dynamic>> chatParseReactions(
  dynamic raw, {
  int? currentUserId,
}) {
  if (raw is! List) return const [];
  final result = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final emoji = item['emoji']?.toString() ?? '';
    if (emoji.isEmpty) continue;
    final userIds = _userIdsOf(item['user_ids']);
    final count = item['count'] is int
        ? item['count'] as int
        : userIds.length;
    result.add({
      'emoji': emoji,
      'count': count,
      'user_ids': userIds,
      'reacted_by_me': currentUserId != null && userIds.contains(currentUserId),
    });
  }
  return result;
}

List<int> _userIdsOf(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => e is int ? e : int.tryParse('$e'))
      .whereType<int>()
      .toList();
}

class ChatMessageReactionsRow extends StatelessWidget {
  const ChatMessageReactionsRow({
    super.key,
    required this.reactions,
    required this.alignEnd,
    this.onReactionTap,
  });

  final List<Map<String, dynamic>> reactions;
  final bool alignEnd;
  final void Function(String emoji)? onReactionTap;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Wrap(
        alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
        spacing: 4,
        runSpacing: 4,
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
        ],
      ),
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
        ? theme.colorScheme.primary.withValues(alpha: 0.5)
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.5);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(emoji),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 14)),
              if (count > 1) ...[
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
