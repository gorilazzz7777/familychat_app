import 'package:flutter/material.dart';

class ChatComposeInput extends StatelessWidget {
  const ChatComposeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onAttach,
    required this.onSend,
    this.sending = false,
    this.showAttach = true,
    this.hintText = 'Сообщение...',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final bool sending;
  final bool showAttach;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
              onSubmitted: (_) => onSend(),
            ),
          ),
          IconButton(
            tooltip: 'Отправить',
            onPressed: sending ? null : onSend,
            icon: Icon(Icons.send_rounded, color: scheme.primary),
          ),
        ],
      ),
    );
  }
}
