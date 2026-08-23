import 'package:flutter/material.dart';

import 'chat_emoji_picker_sheet.dart';
import 'chat_gif_picker_panel.dart';
import '../../data/chat_gif_item.dart';

enum ChatComposePickerTab { emoji, gif }

/// Панель под композом: вкладки Смайлы / GIF.
class ChatComposePickerPanel extends StatelessWidget {
  const ChatComposePickerPanel({
    super.key,
    required this.tab,
    required this.onTabChanged,
    required this.emojiController,
    required this.onGifSelected,
    this.onCollapse,
  });

  final ChatComposePickerTab tab;
  final ValueChanged<ChatComposePickerTab> onTabChanged;
  final TextEditingController emojiController;
  final void Function(ChatGifItem item) onGifSelected;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: cs.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: SegmentedButton<ChatComposePickerTab>(
              segments: const [
                ButtonSegment(
                  value: ChatComposePickerTab.emoji,
                  label: Text('Смайлы'),
                  icon: Icon(Icons.emoji_emotions_outlined, size: 18),
                ),
                ButtonSegment(
                  value: ChatComposePickerTab.gif,
                  label: Text('GIF'),
                  icon: Icon(Icons.gif_box_outlined, size: 18),
                ),
              ],
              selected: {tab},
              onSelectionChanged: (next) {
                if (next.isEmpty) return;
                onTabChanged(next.first);
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ),
        if (tab == ChatComposePickerTab.emoji)
          ChatEmojiPickerPanel(
            controller: emojiController,
            onCollapse: onCollapse,
          )
        else
          ChatGifPickerPanel(
            onSelected: onGifSelected,
            onCollapse: onCollapse,
          ),
      ],
    );
  }
}
