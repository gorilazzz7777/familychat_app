import 'chat_realtime_utils.dart';

typedef ChatRealtimeHandler = void Function(Map<String, dynamic> event);

/// Applies WS events to an open conversation message list.
///
/// Returns updated messages, or null if nothing changed / needs full reload.
class ChatConversationSession {
  ChatConversationSession({this.threadId});

  int? threadId;
  List<Map<String, dynamic>> messages = [];

  /// `true` = caller should HTTP-reload history (`chat_refresh`).
  bool get wantsReload => _wantsReload;
  bool _wantsReload = false;

  void clearReloadFlag() => _wantsReload = false;

  /// Handle one normalized realtime event.
  /// Returns new message list if UI should setState; null if no local change
  /// (or reload requested — check [wantsReload]).
  List<Map<String, dynamic>>? applyEvent(Map<String, dynamic> event) {
    final name = event['event']?.toString();
    if (name == 'chat_refresh') {
      _wantsReload = true;
      return null;
    }
    if (name != 'chat_message') return null;

    final raw = event['message'];
    if (raw is! Map) return null;
    final msg = chatNormalizeMap(Map<dynamic, dynamic>.from(raw));
    if (!chatMessageBelongsToThread(msg, threadId)) return null;

    final id = chatAsInt(msg['id']);
    if (id != null &&
        messages.any((m) => chatAsInt(m['id']) == id)) {
      return null;
    }
    messages = chatUpsertMessage(messages, msg);
    return messages;
  }
}
