import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chat_compose_circle_button.dart';

/// Круглая кнопка смайлов / клавиатуры слева от отправки.
class ChatComposeEmojiButton extends StatelessWidget {
  const ChatComposeEmojiButton({
    super.key,
    required this.open,
    required this.onPressed,
  });

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ChatComposeCircleButton(
      tooltip: open ? 'Клавиатура' : 'Смайлы',
      icon: open ? Icons.keyboard_alt_outlined : Icons.emoji_emotions_outlined,
      iconColor: theme.colorScheme.onSurface,
      onTap: onPressed,
    );
  }
}

/// Панель эмодзи под строкой ввода (поле сообщения остаётся видимым).
class ChatEmojiPickerPanel extends StatelessWidget {
  const ChatEmojiPickerPanel({
    super.key,
    required this.controller,
  });

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final height = (MediaQuery.sizeOf(context).height * 0.38)
        .clamp(260.0, 360.0);

    return Material(
      color: cs.surface,
      child: SizedBox(
        height: height,
        child: EmojiPicker(
          textEditingController: controller,
          config: Config(
            height: height,
            locale: const Locale('ru'),
            checkPlatformCompatibility: true,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: cs.surface,
              columns: 8,
              emojiSizeMax: 28 *
                  (defaultTargetPlatform == TargetPlatform.iOS ? 1.2 : 1.0),
            ),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: cs.surface,
              indicatorColor: cs.primary,
              iconColor: Colors.grey,
              iconColorSelected: cs.primary,
              extraTab: CategoryExtraTab.SEARCH,
            ),
            bottomActionBarConfig: BottomActionBarConfig(
              backgroundColor: cs.surface,
              buttonColor: cs.primary,
              buttonIconColor: cs.onPrimary,
            ),
            searchViewConfig: SearchViewConfig(
              backgroundColor: cs.surface,
              buttonIconColor: Colors.grey,
              hintText: 'Поиск смайлов',
            ),
            skinToneConfig: SkinToneConfig(
              dialogBackgroundColor: cs.surface,
              indicatorColor: cs.primary,
            ),
          ),
        ),
      ),
    );
  }
}
