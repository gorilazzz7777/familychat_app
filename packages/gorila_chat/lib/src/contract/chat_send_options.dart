/// Параметры отправки (обычная / без звука / отложенная / AI).
class ChatSendOptions {
  const ChatSendOptions({
    this.silent = false,
    this.scheduledAt,
    this.aiAssist = false,
  });

  final bool silent;
  final DateTime? scheduledAt;
  final bool aiAssist;

  bool get isScheduled =>
      scheduledAt != null && scheduledAt!.isAfter(DateTime.now());

  static const normal = ChatSendOptions();
  static const ai = ChatSendOptions(aiAssist: true);
}
