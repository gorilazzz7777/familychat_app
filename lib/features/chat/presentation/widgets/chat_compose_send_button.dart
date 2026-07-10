import 'package:flutter/material.dart';

import '../../data/chat_send_options.dart';
import 'chat_send_options_sheet.dart';

/// Кнопка отправки: короткий тап — обычная отправка, долгий — режимы.
class ChatComposeSendButton extends StatelessWidget {
  const ChatComposeSendButton({
    super.key,
    required this.onSend,
  });

  final void Function(ChatSendOptions options) onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onSend(ChatSendOptions.normal),
        onLongPress: () async {
          final options = await ChatSendOptionsSheet.show(context);
          if (options == null) return;
          onSend(options);
        },
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.send_rounded,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
