import 'package:flutter/material.dart';

import 'family_input_styles.dart';

/// Скруглённое поле ввода с кнопкой отправки внутри (стиль чата).
class FamilyComposeInput extends StatelessWidget {
  const FamilyComposeInput({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = 'Сообщение...',
    this.minLines = 1,
    this.maxLines = 5,
    this.leading,
    this.trailing,
    this.onSend,
    this.sending = false,
    this.textInputAction = TextInputAction.newline,
    this.fillColor,
    this.borderColor,
    this.textColor,
    this.hintColor,
    this.sendIconColor,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final int minLines;
  final int maxLines;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onSend;
  final bool sending;
  final TextInputAction textInputAction;
  final Color? fillColor;
  final Color? borderColor;
  final Color? textColor;
  final Color? hintColor;
  final Color? sendIconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabledSend = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
    final sendButton = trailing ??
        IconButton(
          tooltip: 'Отправить',
          onPressed: sending ? null : onSend,
          icon: sending
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: sendIconColor ?? theme.colorScheme.primary,
                  ),
                )
              : Icon(
                  Icons.send_rounded,
                  color: onSend == null
                      ? disabledSend
                      : (sendIconColor ?? theme.colorScheme.primary),
                ),
          visualDensity: VisualDensity.compact,
        );

    return DecoratedBox(
      decoration: FamilyInputStyles.composeShellDecoration(
        theme,
        fillColor: fillColor,
        borderColor: borderColor,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (leading != null) leading!,
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.multiline,
              minLines: minLines,
              maxLines: maxLines,
              textInputAction: textInputAction,
              style: textColor != null ? TextStyle(color: textColor) : null,
              onSubmitted: onSend != null && textInputAction == TextInputAction.send
                  ? (_) => onSend!()
                  : null,
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: hintColor != null ? TextStyle(color: hintColor) : null,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(
                  leading == null ? 16 : 0,
                  10,
                  0,
                  10,
                ),
                isDense: true,
              ),
            ),
          ),
          sendButton,
        ],
      ),
    );
  }
}
