import 'package:flutter/material.dart';

import '../../contract/chat_send_options.dart';
import 'chat_send_options_sheet.dart';

class ChatComposeInput extends StatelessWidget {
  const ChatComposeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onAttach,
    required this.onSend,
    this.sending = false,
    this.showAttach = true,
    this.showAiAssist = false,
    this.showSilent = false,
    this.showSchedule = false,
    this.hintText = 'Сообщение...',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  /// Короткий тап — обычная отправка; long-press меню вызывает [onSend] с опциями.
  final void Function(ChatSendOptions options) onSend;
  final bool sending;
  final bool showAttach;
  final bool showAiAssist;
  final bool showSilent;
  final bool showSchedule;
  final String hintText;

  Future<void> _onLongPressSend(BuildContext context) async {
    final options = await ChatSendOptionsSheet.show(
      context,
      showSilent: showSilent,
      showSchedule: showSchedule,
      showAiAssist: showAiAssist,
    );
    if (options == null) return;
    onSend(options);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasLongPressMenu = showAiAssist || showSilent || showSchedule;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showAttach)
            IconButton(
              tooltip: 'Вложение',
              onPressed: onAttach,
              icon: const Icon(Icons.attach_file),
            ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.multiline,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: hintText,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                isDense: true,
              ),
              onSubmitted: (_) => onSend(ChatSendOptions.normal),
            ),
          ),
          IconButton(
            tooltip: 'Отправить',
            onPressed: sending ? null : () => onSend(ChatSendOptions.normal),
            onLongPress: sending || !hasLongPressMenu
                ? null
                : () => _onLongPressSend(context),
            icon: Icon(Icons.send_rounded, color: scheme.primary),
          ),
        ],
      ),
    );
  }
}
