/// Канал доставки для тредов со связкой Telegram Secretary / dual-групп.
enum ChatDeliveryChannel {
  /// Dual-write: пуш по last_counterpart (пусто → FC).
  auto,

  /// Dual-write: пуш в Family Space, Telegram без звука.
  notifyFamilychat,

  /// Dual-write: пуш в Telegram, Family Space без звука.
  telegram,

  /// Только Family Space — в Telegram не зеркалить (приватность).
  familychatOnly,
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

  /// Dual-write modes (history in both FC and Telegram).
  bool get mirrorsToTelegram => switch (deliveryChannel) {
        ChatDeliveryChannel.familychatOnly => false,
        ChatDeliveryChannel.auto ||
        ChatDeliveryChannel.notifyFamilychat ||
        ChatDeliveryChannel.telegram =>
          true,
      };

  String? get deliveryChannelApi {
    return switch (deliveryChannel) {
      ChatDeliveryChannel.auto => null,
      ChatDeliveryChannel.notifyFamilychat => 'notify_familychat',
      ChatDeliveryChannel.telegram => 'telegram',
      ChatDeliveryChannel.familychatOnly => 'familychat',
    };
  }

  static const normal = ChatSendOptions();
  static const ai = ChatSendOptions(aiAssist: true);
}
