import 'package:flutter/material.dart';

import 'chat_message_quote.dart';

/// Полоска «ответ на …» над полем ввода.
class ChatReplyComposeBar extends StatelessWidget {
  const ChatReplyComposeBar({
    super.key,
    required this.senderName,
    required this.body,
    required this.onCancel,
  });

  final String senderName;
  final String body;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: ChatMessageQuote(
                title: senderName,
                body: body,
                accentColor: theme.colorScheme.primary,
                textColor: theme.colorScheme.onSurface,
              ),
            ),
            IconButton(
              tooltip: 'Отменить ответ',
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}
