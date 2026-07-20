import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const kGorilaQuickReactionEmojis = [
  '👍',
  '❤️',
  '😂',
  '😮',
  '😢',
  '🔥',
];

class ChatMessageMenuResult {
  const ChatMessageMenuResult.action(this.action) : reactionEmoji = null;

  const ChatMessageMenuResult.reaction(this.reactionEmoji) : action = null;

  final String? action;
  final String? reactionEmoji;
}

/// Меню действий над сообщением (тап / long-press).
class ChatMessageActionsSheet {
  static Future<ChatMessageMenuResult?> show(
    BuildContext context, {
    bool showReactions = false,
    bool canReply = true,
    bool canEdit = false,
    bool canCopy = true,
    bool canForward = true,
    bool canSelect = true,
    bool canPin = false,
    bool isPinned = false,
    bool canDeleteForEveryone = false,
    bool canDeleteForMe = false,
  }) {
    return showModalBottomSheet<ChatMessageMenuResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ChatMessageActionsSheetBody(
        showReactions: showReactions,
        canReply: canReply,
        canEdit: canEdit,
        canCopy: canCopy,
        canForward: canForward,
        canSelect: canSelect,
        canPin: canPin,
        isPinned: isPinned,
        canDeleteForEveryone: canDeleteForEveryone,
        canDeleteForMe: canDeleteForMe,
      ),
    );
  }
}

class _ChatMessageActionsSheetBody extends StatefulWidget {
  const _ChatMessageActionsSheetBody({
    required this.showReactions,
    required this.canReply,
    required this.canEdit,
    required this.canCopy,
    required this.canForward,
    required this.canSelect,
    required this.canPin,
    required this.isPinned,
    required this.canDeleteForEveryone,
    required this.canDeleteForMe,
  });

  final bool showReactions;
  final bool canReply;
  final bool canEdit;
  final bool canCopy;
  final bool canForward;
  final bool canSelect;
  final bool canPin;
  final bool isPinned;
  final bool canDeleteForEveryone;
  final bool canDeleteForMe;

  @override
  State<_ChatMessageActionsSheetBody> createState() =>
      _ChatMessageActionsSheetBodyState();
}

class _ChatMessageActionsSheetBodyState
    extends State<_ChatMessageActionsSheetBody> {
  bool _expandedPicker = false;

  void _pickReaction(String emoji) {
    Navigator.pop(context, ChatMessageMenuResult.reaction(emoji));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final showDelete = widget.canDeleteForEveryone || widget.canDeleteForMe;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showReactions) ...[
              const SizedBox(height: 8),
              _QuickReactionsBar(
                expanded: _expandedPicker,
                onEmojiTap: _pickReaction,
                onExpandTap: () =>
                    setState(() => _expandedPicker = !_expandedPicker),
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
            if (widget.canReply)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Ответить'),
                onTap: () => Navigator.pop(
                  context,
                  const ChatMessageMenuResult.action('reply'),
                ),
              ),
            if (widget.canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Редактировать'),
                onTap: () => Navigator.pop(
                  context,
                  const ChatMessageMenuResult.action('edit'),
                ),
              ),
            if (widget.canCopy)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Копировать'),
                onTap: () => Navigator.pop(
                  context,
                  const ChatMessageMenuResult.action('copy'),
                ),
              ),
            if (widget.canForward)
              ListTile(
                leading: const Icon(Icons.forward_outlined),
                title: const Text('Переслать'),
                onTap: () => Navigator.pop(
                  context,
                  const ChatMessageMenuResult.action('forward'),
                ),
              ),
            if (widget.canSelect)
              ListTile(
                leading: const Icon(Icons.checklist_outlined),
                title: const Text('Выбрать'),
                onTap: () => Navigator.pop(
                  context,
                  const ChatMessageMenuResult.action('select'),
                ),
              ),
            if (widget.canPin)
              ListTile(
                leading: Icon(
                  widget.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: Text(widget.isPinned ? 'Открепить' : 'Закрепить'),
                onTap: () => Navigator.pop(
                  context,
                  ChatMessageMenuResult.action(
                    widget.isPinned ? 'unpin' : 'pin',
                  ),
                ),
              ),
            if (showDelete)
              ListTile(
                leading:
                    Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text(
                  'Удалить',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: () => Navigator.pop(
                  context,
                  ChatMessageMenuResult.action(
                    widget.canDeleteForEveryone ? 'delete' : 'delete_for_me',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _QuickReactionsBar extends StatelessWidget {
  const _QuickReactionsBar({
    required this.expanded,
    required this.onEmojiTap,
    required this.onExpandTap,
  });

  final bool expanded;
  final ValueChanged<String> onEmojiTap;
  final VoidCallback onExpandTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
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
                  onTap: () => onEmojiTap(emoji),
                  borderRadius: BorderRadius.circular(24),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Text(emoji, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
                ),
              ),
            ),
          Material(
            color: expanded
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              onTap: onExpandTap,
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  expanded ? Icons.expand_less : Icons.add_reaction_outlined,
                  color: expanded
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
