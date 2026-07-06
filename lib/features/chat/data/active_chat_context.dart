/// Какой чат сейчас открыт на экране (для подавления push в foreground).
class ActiveChatContext {
  ActiveChatContext._();
  static final ActiveChatContext instance = ActiveChatContext._();

  int? _openThreadId;

  int? get openThreadId => _openThreadId;

  void setOpenThread(int? threadId) => _openThreadId = threadId;

  bool isViewingThread(int threadId) => _openThreadId == threadId;
}
