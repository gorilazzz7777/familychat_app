import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
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

/// Local toggle for instant UI — server reconcile happens in the background.
List<Map<String, dynamic>> optimisticToggleMediaReaction(
  List<Map<String, dynamic>> reactions, {
  required String emoji,
}) {
  final target = emoji.trim();
  if (target.isEmpty) {
    return [
      for (final r in reactions) Map<String, dynamic>.from(r),
    ];
  }

  final myCurrent = mediaReactionsMyEmoji(reactions);
  final removing = myCurrent == target;
  final byEmoji = <String, Map<String, dynamic>>{};
  for (final reaction in reactions) {
    final e = reaction['emoji']?.toString().trim() ?? '';
    if (e.isEmpty) continue;
    byEmoji[e] = Map<String, dynamic>.from(reaction);
  }

  void adjust(String e, {required bool addMine}) {
    final existing = byEmoji[e];
    if (existing == null) {
      if (!addMine) return;
      byEmoji[e] = {
        'emoji': e,
        'count': 1,
        'user_ids': <int>[],
        'users': <Map<String, dynamic>>[],
        'reacted_by_me': true,
      };
      return;
    }
    var count = existing['count'] is int
        ? existing['count'] as int
        : int.tryParse('${existing['count']}') ?? 0;
    if (addMine) {
      count += 1;
      existing['reacted_by_me'] = true;
    } else {
      count = (count - 1).clamp(0, 1 << 30);
      existing['reacted_by_me'] = false;
    }
    if (count <= 0) {
      byEmoji.remove(e);
    } else {
      existing['count'] = count;
      byEmoji[e] = existing;
    }
  }

  if (myCurrent != null) {
    adjust(myCurrent, addMine: false);
  }
  if (!removing) {
    adjust(target, addMine: true);
  }
  return byEmoji.values.toList(growable: false);
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

/// Default quick reaction for double-tap on a feed post.
const kFeedDoubleTapReactionEmoji = '❤️';

/// Пачка эмодзи реакций «друг на друге» (без счётчиков по видам).
///
/// Слева направо: своя реакция (если есть), затем остальные.
/// Своя рисуется сверху по z-order. Пустой слот-сердце по умолчанию выключен.
class FeedReactionsStack extends StatelessWidget {
  const FeedReactionsStack({
    super.key,
    required this.reactions,
    this.myEmoji,
    this.onTap,
    this.emojiSize = 18,
    this.overlap = 10,
    this.showMinePlaceholder = false,
  });

  final List<Map<String, dynamic>> reactions;
  /// Своя эмодзи, если уже поставили; иначе optional placeholder.
  final String? myEmoji;
  final VoidCallback? onTap;
  final double emojiSize;
  final double overlap;
  /// Показывать серое сердце слева, даже когда своей реакции ещё нет.
  final bool showMinePlaceholder;

  List<String> get _otherEmojis {
    final mine = myEmoji?.trim();
    final out = <String>[];
    final seen = <String>{};
    for (final reaction in reactions) {
      final emoji = reaction['emoji']?.toString().trim() ?? '';
      if (emoji.isEmpty) continue;
      if (mine != null && mine.isNotEmpty && emoji == mine) continue;
      if (!seen.add(emoji)) continue;
      out.add(emoji);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final mine = myEmoji?.trim();
    final hasMine = mine != null && mine.isNotEmpty;
    final others = _otherEmojis;
    final showMineSlot = hasMine || showMinePlaceholder;
    if (!showMineSlot && others.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final diameter = emojiSize + 12;
    final slotCount = (showMineSlot ? 1 : 0) + others.length;
    final width = diameter + (slotCount - 1) * (diameter - overlap);

    Widget chip({required Widget child}) {
      return Container(
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
        child: child,
      );
    }

    // Paint right→left so the leftmost (mine) ends up on top.
    final children = <Widget>[];
    for (var i = slotCount - 1; i >= 0; i--) {
      final Widget content;
      if (showMineSlot && i == 0) {
        content = hasMine
            ? Text(mine, style: TextStyle(fontSize: emojiSize, height: 1))
            : Icon(
                LucideIcons.heart,
                size: emojiSize,
                color: cs.onSurfaceVariant,
              );
      } else {
        final otherIndex = showMineSlot ? i - 1 : i;
        content = Text(
          others[otherIndex],
          style: TextStyle(fontSize: emojiSize, height: 1),
        );
      }
      children.add(
        Positioned(
          left: i * (diameter - overlap),
          child: chip(child: content),
        ),
      );
    }

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
              children: children,
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
                LucideIcons.face_slightly_smiling_plus,
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

/// Результат long-press меню поста ленты.
class FeedPostActionsResult {
  const FeedPostActionsResult.reaction(this.reactionEmoji) : action = null;

  const FeedPostActionsResult.action(this.action) : reactionEmoji = null;

  final String? reactionEmoji;
  /// `viewed` | `reactions` | `navigate` | `delete`
  final String? action;
}

/// Меню поста: реакции сверху, затем просмотры / реакции / открыть / удалить.
Future<FeedPostActionsResult?> showFeedPostActionsSheet(
  BuildContext context, {
  required bool canReact,
  required bool hasReactions,
  required String navigateLabel,
  required bool canDelete,
}) {
  return showModalBottomSheet<FeedPostActionsResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _FeedPostActionsSheetBody(
      canReact: canReact,
      hasReactions: hasReactions,
      navigateLabel: navigateLabel,
      canDelete: canDelete,
    ),
  );
}

class _FeedPostActionsSheetBody extends StatefulWidget {
  const _FeedPostActionsSheetBody({
    required this.canReact,
    required this.hasReactions,
    required this.navigateLabel,
    required this.canDelete,
  });

  final bool canReact;
  final bool hasReactions;
  final String navigateLabel;
  final bool canDelete;

  @override
  State<_FeedPostActionsSheetBody> createState() =>
      _FeedPostActionsSheetBodyState();
}

class _FeedPostActionsSheetBodyState extends State<_FeedPostActionsSheetBody> {
  bool _expandedPicker = false;

  void _pickReaction(String emoji) {
    Navigator.pop(context, FeedPostActionsResult.reaction(emoji));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.canReact) ...[
              const SizedBox(height: 4),
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final emoji in kGorilaQuickReactionEmojis)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Material(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(24),
                          child: InkWell(
                            onTap: () => _pickReaction(emoji),
                            borderRadius: BorderRadius.circular(24),
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 26),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Material(
                      color: _expandedPicker
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(24),
                      child: InkWell(
                        onTap: () => setState(
                          () => _expandedPicker = !_expandedPicker,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            _expandedPicker
                                ? LucideIcons.chevron_up
                                : LucideIcons.face_slightly_smiling_plus,
                            color: _expandedPicker
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_expandedPicker)
                SizedBox(
                  height: 280,
                  child: EmojiPicker(
                    onEmojiSelected: (category, emoji) {
                      _pickReaction(emoji.emoji);
                    },
                    config: Config(
                      height: 280,
                      checkPlatformCompatibility: true,
                      emojiViewConfig: EmojiViewConfig(
                        backgroundColor: theme.colorScheme.surface,
                        columns: 8,
                        emojiSizeMax: 28 *
                            (defaultTargetPlatform == TargetPlatform.iOS
                                ? 1.2
                                : 1.0),
                      ),
                      categoryViewConfig: CategoryViewConfig(
                        backgroundColor: theme.colorScheme.surface,
                        indicatorColor: theme.colorScheme.primary,
                        iconColor: Colors.grey,
                        iconColorSelected: theme.colorScheme.primary,
                      ),
                      bottomActionBarConfig: const BottomActionBarConfig(
                        enabled: false,
                      ),
                      searchViewConfig: SearchViewConfig(
                        backgroundColor: theme.colorScheme.surface,
                        hintText: 'Поиск эмодзи',
                      ),
                    ),
                  ),
                ),
              const Divider(height: 1),
            ],
            ListTile(
              leading: const Icon(LucideIcons.eye),
              title: const Text('Просмотрено'),
              onTap: () => Navigator.pop(
                context,
                const FeedPostActionsResult.action('viewed'),
              ),
            ),
            if (widget.hasReactions)
              ListTile(
                leading: Icon(
                  LucideIcons.heart,
                  color: theme.colorScheme.onSurface,
                ),
                title: const Text('Реакции'),
                onTap: () => Navigator.pop(
                  context,
                  const FeedPostActionsResult.action('reactions'),
                ),
              ),
            ListTile(
              leading: Icon(
                LucideIcons.external_link,
                color: theme.colorScheme.primary,
              ),
              title: Text(widget.navigateLabel),
              onTap: () => Navigator.pop(
                context,
                const FeedPostActionsResult.action('navigate'),
              ),
            ),
            if (widget.canDelete)
              ListTile(
                leading: Icon(
                  LucideIcons.trash,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  'Удалить',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: () => Navigator.pop(
                  context,
                  const FeedPostActionsResult.action('delete'),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
