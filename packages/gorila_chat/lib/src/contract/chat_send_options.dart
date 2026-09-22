/// Канал доставки для тредов со связкой Telegram Secretary.
enum ChatDeliveryChannel {
  /// Как last_counterpart на сервере.
  auto,

  /// Только Family Space (не зеркалить в Telegram).
  familychat,

  /// Принудительно в Telegram.
  telegram,
}

/// Параметры отправки (обычная / без звука / отложенная / AI / канал).
class ChatSendOptions {
  const ChatSendOptions({
    this.silent = false,
    this.scheduledAt,
    this.aiAssist = false,
    this.deliveryChannel = ChatDeliveryChannel.auto,
    this.preferenceOnly = false,
  });

  final bool silent;
  final DateTime? scheduledAt;
  final bool aiAssist;
  final ChatDeliveryChannel deliveryChannel;

  /// Только сменить sticky-режим, без отправки.
  final bool preferenceOnly;

  bool get isScheduled =>
      scheduledAt != null && scheduledAt!.isAfter(DateTime.now());

  /// Legacy flag for API callers.
  bool get deliverToTelegram =>
      deliveryChannel == ChatDeliveryChannel.telegram;

  String? get deliveryChannelApi {
    return switch (deliveryChannel) {
      ChatDeliveryChannel.auto => null,
      ChatDeliveryChannel.familychat => 'familychat',
      ChatDeliveryChannel.telegram => 'telegram',
    };
  }

  static const normal = ChatSendOptions();
  static const ai = ChatSendOptions(aiAssist: true);
}
