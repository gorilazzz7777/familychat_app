import 'package:flutter/material.dart';

/// Поле ввода сообщения с кнопками вложения и отправки внутри блока.
class ChatComposeInput extends StatelessWidget {
  const ChatComposeInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onAttach,
    required this.onSend,
    this.hintText = 'Сообщение...',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = theme.colorScheme.surfaceContainerHighest;
    final border = theme.colorScheme.outlineVariant.withValues(alpha: 0.55);

    return Material(
      color: fill,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Вложение',
            onPressed: onAttach,
            icon: Icon(
              Icons.attach_file,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: hintText,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
                isDense: true,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Отправить',
            onPressed: onSend,
            icon: Icon(
              Icons.send_rounded,
              color: theme.colorScheme.primary,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
