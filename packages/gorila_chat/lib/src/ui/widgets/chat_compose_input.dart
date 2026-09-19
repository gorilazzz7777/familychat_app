import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../contract/chat_send_options.dart';
import 'chat_send_options_sheet.dart';

class ChatComposeInput extends StatefulWidget {
  const ChatComposeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onAttach,
    required this.onSend,
    this.sending = false,
    this.showAttach = true,
    this.showEmoji = false,
    this.showAiAssist = false,
    this.showSilent = false,
    this.showSchedule = false,
    this.hintText = 'Сообщение...',
    this.leading,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  /// Короткий тап — обычная отправка; long-press меню вызывает [onSend] с опциями.
  final void Function(ChatSendOptions options) onSend;
  final bool sending;
  final bool showAttach;
  final bool showEmoji;
  final bool showAiAssist;
  final bool showSilent;
  final bool showSchedule;
  final String hintText;
  /// Optional control inside the field on the left (before attach / text).
  final Widget? leading;

  @override
  State<ChatComposeInput> createState() => _ChatComposeInputState();
}

class _ChatComposeInputState extends State<ChatComposeInput> {
  bool _emojiOpen = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant ChatComposeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (widget.focusNode.hasFocus && _emojiOpen) {
      setState(() => _emojiOpen = false);
    }
  }

  void _toggleEmoji() {
    if (_emojiOpen) {
      setState(() => _emojiOpen = false);
      widget.focusNode.requestFocus();
      return;
    }
    widget.focusNode.unfocus();
    setState(() => _emojiOpen = true);
  }

  void _closeEmoji() {
    if (!_emojiOpen) return;
    setState(() => _emojiOpen = false);
  }

  Future<void> _onLongPressSend() async {
    final options = await ChatSendOptionsSheet.show(
      context,
      showSilent: widget.showSilent,
      showSchedule: widget.showSchedule,
      showAiAssist: widget.showAiAssist,
    );
    if (options == null) return;
    widget.onSend(options);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasLongPressMenu =
        widget.showAiAssist || widget.showSilent || widget.showSchedule;
    final pickerHeight = (MediaQuery.sizeOf(context).height * 0.38)
        .clamp(200.0, 360.0);

    return PopScope(
      canPop: !_emojiOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeEmoji();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (widget.leading != null) widget.leading!,
                if (widget.showAttach)
                  IconButton(
                    tooltip: 'Вложение',
                    onPressed: widget.onAttach,
                    icon: const Icon(LucideIcons.paperclip),
                  ),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    keyboardType: TextInputType.multiline,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    readOnly: _emojiOpen,
                    showCursor: true,
                    onTap: () {
                      if (_emojiOpen) _closeEmoji();
                    },
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                      isDense: true,
                    ),
                    onSubmitted: (_) => widget.onSend(ChatSendOptions.normal),
                  ),
                ),
                if (widget.showEmoji)
                  IconButton(
                    tooltip: _emojiOpen ? 'Клавиатура' : 'Смайлы',
                    onPressed: widget.sending ? null : _toggleEmoji,
                    icon: Icon(
                      _emojiOpen
                          ? LucideIcons.keyboard
                          : LucideIcons.face_slightly_smiling,
                    ),
                  ),
                IconButton(
                  tooltip: 'Отправить',
                  onPressed: widget.sending
                      ? null
                      : () => widget.onSend(ChatSendOptions.normal),
                  onLongPress: widget.sending || !hasLongPressMenu
                      ? null
                      : _onLongPressSend,
                  icon: Icon(LucideIcons.send, color: scheme.primary),
                ),
              ],
            ),
          ),
          if (widget.showEmoji && _emojiOpen) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: pickerHeight,
              child: Material(
                color: scheme.surface,
                child: EmojiPicker(
                  textEditingController: widget.controller,
                  config: Config(
                    height: pickerHeight,
                    locale: const Locale('ru'),
                    checkPlatformCompatibility: true,
                    emojiViewConfig: EmojiViewConfig(
                      backgroundColor: scheme.surface,
                      columns: 8,
                      emojiSizeMax: 28 *
                          (defaultTargetPlatform == TargetPlatform.iOS
                              ? 1.2
                              : 1.0),
                    ),
                    categoryViewConfig: CategoryViewConfig(
                      backgroundColor: scheme.surface,
                      indicatorColor: scheme.primary,
                      iconColor: Colors.grey,
                      iconColorSelected: scheme.primary,
                    ),
                    bottomActionBarConfig: BottomActionBarConfig(
                      backgroundColor: scheme.surface,
                      buttonColor: scheme.primary,
                      buttonIconColor: scheme.onSurface,
                    ),
                    searchViewConfig: SearchViewConfig(
                      backgroundColor: scheme.surface,
                      hintText: 'Поиск эмодзи',
                    ),
                    skinToneConfig: SkinToneConfig(
                      dialogBackgroundColor: scheme.surface,
                      indicatorColor: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
