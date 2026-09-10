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
        final id = mediaReactionUserId(e);
        if (id != null) userIds.add(id);
      }
    }
    final count = item['count'] is int
        ? item['count'] as int
        : int.tryParse('${item['count']}') ?? userIds.length;
    final users = <Map<String, dynamic>>[];
    final rawUsers = item['users'];
    if (rawUsers is List) {
      for (final user in rawUsers) {
        if (user is Map) {
          users.add(Map<String, dynamic>.from(user));
        }
      }
    }
    result.add({
      'emoji': emoji,
      'count': count,
      'user_ids': userIds,
      'users': users,
      'reacted_by_me': item['reacted_by_me'] == true,
    });
  }
  return result;
}

int? mediaReactionUserId(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  final text = '$raw'.trim();
  if (text.isEmpty || text == 'null') return null;
  return int.tryParse(text);
}

/// Плоский список людей, поставивших реакцию (emoji + user_id / профиль).
List<Map<String, dynamic>> mediaReactionPeople(
  List<Map<String, dynamic>> reactions,
) {
  final people = <Map<String, dynamic>>[];
  for (final reaction in reactions) {
    final emoji = reaction['emoji']?.toString() ?? '';
    final seen = <int>{};
    final users = reaction['users'];
    if (users is List) {
      for (final user in users) {
        if (user is! Map) continue;
        final map = Map<String, dynamic>.from(user);
        map['emoji'] = emoji;
        final userId = mediaReactionUserId(map['user_id']) ??
            mediaReactionUserId(map['id']);
        if (userId != null) {
          map['user_id'] = userId;
          seen.add(userId);
        }
        people.add(map);
      }
    }
    final userIds = reaction['user_ids'];
    if (userIds is! List) continue;
    for (final rawId in userIds) {
      final userId = mediaReactionUserId(rawId);
      if (userId == null || seen.contains(userId)) continue;
      seen.add(userId);
      people.add({
        'user_id': userId,
        'emoji': emoji,
      });
    }
  }
  return people;
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

String? mediaReactionsMyEmoji(List<Map<String, dynamic>> reactions) {
  for (final reaction in reactions) {
    if (reaction['reacted_by_me'] != true) continue;
    final emoji = reaction['emoji']?.toString().trim() ?? '';
    if (emoji.isNotEmpty) return emoji;
  }
  return null;
}

int _asCommentsCount(dynamic raw) {
  if (raw is int) return raw;
  return int.tryParse('$raw') ?? 0;
}

class FeedStoredEngagement {
  const FeedStoredEngagement({
    this.reactions = const [],
    this.commentsCount = 0,
  });

  final List<Map<String, dynamic>> reactions;
  final int commentsCount;
}

FeedStoredEngagement feedEngagementFromMap(Map<dynamic, dynamic>? raw) {
  if (raw == null) return const FeedStoredEngagement();
  return FeedStoredEngagement(
    reactions: parseMediaReactions(raw['reactions']),
    commentsCount: _asCommentsCount(raw['comments_count']),
  );
}

FeedStoredEngagement feedEngagementFromEvent(
  Map<String, dynamic> event, {
  int? attachmentId,
}) {
  if (attachmentId != null) {
    final payload = event['payload'];
    if (payload is Map) {
      final attachments = payload['attachments'];
      if (attachments is List) {
        for (final item in attachments) {
          if (item is! Map) continue;
          final id = mediaReactionUserId(item['id'] ?? item['attachment_id']);
          if (id == attachmentId) return feedEngagementFromMap(item);
        }
      }
      final payloadId = mediaReactionUserId(payload['attachment_id']);
      if (payloadId == attachmentId) {
        final fromPayload = feedEngagementFromMap(payload);
        if (fromPayload.reactions.isNotEmpty || fromPayload.commentsCount > 0) {
          return fromPayload;
        }
      }
    }
  }
  return feedEngagementFromMap(event);
}

void writeFeedEngagementToEvent(
  Map<String, dynamic> event, {
  required int attachmentId,
  required List<Map<String, dynamic>> reactions,
  required int commentsCount,
}) {
  event['reactions'] = reactions;
  event['comments_count'] = commentsCount;
  final payload = event['payload'];
  if (payload is! Map) return;
  final payloadMap = payload is Map<String, dynamic>
      ? payload
      : Map<String, dynamic>.from(payload);
  if (payload is! Map<String, dynamic>) {
    event['payload'] = payloadMap;
  }
  final payloadId = mediaReactionUserId(payloadMap['attachment_id']);
  if (payloadId == attachmentId) {
    payloadMap['reactions'] = reactions;
    payloadMap['comments_count'] = commentsCount;
  }
  final attachments = payloadMap['attachments'];
  if (attachments is! List) return;
  for (var i = 0; i < attachments.length; i++) {
    final item = attachments[i];
    if (item is! Map) continue;
    final id = mediaReactionUserId(item['id'] ?? item['attachment_id']);
    if (id != attachmentId) continue;
    final row = item is Map<String, dynamic>
        ? item
        : Map<String, dynamic>.from(item);
    row['reactions'] = reactions;
    row['comments_count'] = commentsCount;
    attachments[i] = row;
  }
}

/// Пачка эмодзи реакций «друг на друге» (без счётчиков по видам).
class FeedReactionsStack extends StatelessWidget {
  const FeedReactionsStack({
    super.key,
    required this.reactions,
    this.onTap,
    this.emojiSize = 18,
    this.overlap = 10,
  });

  final List<Map<String, dynamic>> reactions;
  final VoidCallback? onTap;
  final double emojiSize;
  final double overlap;

  List<String> get _emojis {
    final out = <String>[];
    for (final reaction in reactions) {
      final emoji = reaction['emoji']?.toString().trim() ?? '';
      if (emoji.isEmpty) continue;
      out.add(emoji);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final emojis = _emojis;
    if (emojis.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final diameter = emojiSize + 6;
    final width = diameter + (emojis.length - 1) * (diameter - overlap);

    return Tooltip(
      message: 'Реакция',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(diameter),
          child: SizedBox(
            width: width,
            height: diameter,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < emojis.length; i++)
                  Positioned(
                    left: i * (diameter - overlap),
                    child: Container(
                      width: diameter,
                      height: diameter,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: cs.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: cs.surfaceContainerHighest,
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        emojis[i],
                        style: TextStyle(fontSize: emojiSize, height: 1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
