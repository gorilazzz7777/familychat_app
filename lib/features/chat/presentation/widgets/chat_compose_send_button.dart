import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../data/chat_send_options.dart';
import 'chat_compose_circle_button.dart';

/// Цвет кнопки отправки в режиме Telegram (как акцент TG, не 1:1 UI).
const Color kTelegramSendBlue = Color(0xFF2AABEE);

/// Кнопка отправки: короткий тап — обычная отправка, долгий — режимы.
class ChatComposeSendButton extends StatelessWidget {
  const ChatComposeSendButton({
    super.key,
    required this.onSend,
    this.showAiAssist = false,
    this.showDeliverToTelegram = false,
    this.deliveryChannel = ChatDeliveryChannel.auto,
    this.highlightTelegram = false,
  });

  final void Function(ChatSendOptions options) onSend;
  final bool showAiAssist;
  final bool showDeliverToTelegram;
  final ChatDeliveryChannel deliveryChannel;
  final bool highlightTelegram;

  @override
  Widget build(BuildContext context) {
    return ChatComposeCircleButton(
      tooltip: highlightTelegram ? 'Отправить в Telegram' : 'Отправить',
      icon: LucideIcons.send,
      iconColor: highlightTelegram ? Colors.white : null,
      backgroundColor: highlightTelegram ? kTelegramSendBlue : null,
      borderColor: highlightTelegram ? kTelegramSendBlue : null,
      onTap: () => onSend(ChatSendOptions(deliveryChannel: deliveryChannel)),
      onLongPress: () async {
        final options = await ChatSendOptionsSheet.show(
          context,
          showAiAssist: showAiAssist,
          showDeliveryChannel: showDeliverToTelegram,
          initialChannel: deliveryChannel,
        );
        if (options == null) return;
        onSend(options);
      },
    );
  }
}
