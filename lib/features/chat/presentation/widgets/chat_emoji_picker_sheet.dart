import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chat_compose_circle_button.dart';

/// Круглая кнопка смайлов слева от отправки.
class ChatComposeEmojiButton extends StatelessWidget {
  const ChatComposeEmojiButton({
    super.key,
    required this.controller,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ChatComposeCircleButton(
      tooltip: 'Смайлы',
      icon: Icons.emoji_emotions_outlined,
      iconColor: theme.colorScheme.onSurface,
      onTap: () => ChatEmojiPickerSheet.show(
        context,
        controller: controller,
        focusNode: focusNode,
      ),
    );
  }
}

/// Шторка с полным набором эмодзи (не только системная клавиатура).
class ChatEmojiPickerSheet {
  ChatEmojiPickerSheet._();

  static Future<void> show(
    BuildContext context, {
    required TextEditingController controller,
    FocusNode? focusNode,
  }) async {
    final hadFocus = focusNode?.hasFocus ?? false;
    focusNode?.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        final height =
            (MediaQuery.sizeOf(ctx).height * 0.5).clamp(340.0, 520.0);
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(ctx).bottom,
          ),
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
                      (defaultTargetPlatform == TargetPlatform.iOS
                          ? 1.2
                          : 1.0),
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
      },
    );
    if (hadFocus && context.mounted) {
      focusNode?.requestFocus();
    }
  }
}
