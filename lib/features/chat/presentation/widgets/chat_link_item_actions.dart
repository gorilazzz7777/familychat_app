import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a link the same way as FC chat-info «Ссылки» (external browser).
Future<void> launchChatInfoLink(String rawUrl) async {
  var value = rawUrl.trim();
  if (value.isEmpty) return;
  if (!value.startsWith('http://') &&
      !value.startsWith('https://') &&
      !value.startsWith('tg://')) {
    value = 'https://$value';
  }
  final uri = Uri.tryParse(value);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Close the chat-info sheet, then jump to [messageId] in the conversation.
Future<void> goToChatInfoMessage(
  BuildContext context, {
  required int messageId,
  required Future<void> Function(int messageId) onGoToMessage,
}) async {
  Navigator.of(context).pop();
  await Future<void>.delayed(const Duration(milliseconds: 220));
  await onGoToMessage(messageId);
}

/// Bottom sheet used by FC / TG chat-info «Ссылки» (and media) item taps.
///
/// Keep buttons identical across surfaces — call sites only supply callbacks.
Future<void> showChatLinkItemActions(
  BuildContext context, {
  String openTitle = 'Открыть ссылку',
  IconData openIcon = LucideIcons.external_link,
  Future<void> Function()? onOpen,
  Future<void> Function()? onGoToMessage,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onOpen != null)
            ListTile(
              leading: Icon(openIcon),
              title: Text(openTitle),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
          if (onGoToMessage != null)
            ListTile(
              leading: const Icon(LucideIcons.reply),
              title: const Text('Перейти к сообщению'),
              onTap: () => Navigator.pop(ctx, 'goto'),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'open') await onOpen?.call();
  if (action == 'goto') await onGoToMessage?.call();
}
