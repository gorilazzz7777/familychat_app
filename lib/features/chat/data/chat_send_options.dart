/// Параметры отправки сообщения (обычная / без звука / отложенная).
class ChatSendOptions {
  const ChatSendOptions({
    this.silent = false,
    this.scheduledAt,
  });

  final bool silent;
  final DateTime? scheduledAt;

  bool get isScheduled =>
      scheduledAt != null && scheduledAt!.isAfter(DateTime.now());

  static const normal = ChatSendOptions();
}
