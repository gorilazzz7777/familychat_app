import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/chat/data/chat_message_preview.dart';
import '../../features/chat/data/chat_local_reads.dart';
import '../../features/chat/data/chat_realtime_utils.dart';
import '../local_db/chat_local_store.dart';

/// Одна строка диалога в пуше (как в Telegram).
class ChatPushPreviewLine {
  const ChatPushPreviewLine({
    this.messageId,
    required this.sender,
    required this.text,
    this.timestampMs,
  });

  final int? messageId;
  final String sender;
  final String text;
  final int? timestampMs;

  Map<String, dynamic> toJson() => {
        if (messageId != null) 'message_id': messageId,
        'sender': sender,
        'text': text,
        if (timestampMs != null) 'timestamp_ms': timestampMs,
      };

  factory ChatPushPreviewLine.fromJson(Map<String, dynamic> json) {
    return ChatPushPreviewLine(
      messageId: chatAsInt(json['message_id']),
      sender: json['sender']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      timestampMs: chatAsInt(json['timestamp_ms']),
    );
  }
}

/// Собранное превью чата для локального уведомления.
class ChatPushThreadPreview {
  const ChatPushThreadPreview({
    required this.title,
    required this.collapsedBody,
    required this.expandedBody,
    required this.isGroup,
    required this.lines,
  });

  final String title;
  final String collapsedBody;
  final String expandedBody;
  final bool isGroup;
  final List<ChatPushPreviewLine> lines;

  static const maxMessages = 7;
  static const maxTotalChars = 900;

  static String _prefsKey(int threadId) => 'familychat_push_preview_$threadId';

  static bool isGroupThread(Map<String, dynamic> data) {
    final kind = data['thread_kind']?.toString().toLowerCase() ?? '';
    if (kind == 'direct' || kind == 'dm' || kind == 'private') return false;
    if (kind == 'family' ||
        kind == 'group' ||
        kind == 'channel' ||
        kind == 'family_chat') {
      return true;
    }
    final peer = data['peer_user_id']?.toString().trim() ?? '';
    return peer.isEmpty;
  }

  static Future<void> clear(int threadId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey(threadId));
    } catch (e) {
      debugPrint('[ChatPushPreview] clear failed: $e');
    }
  }

  /// Максимальный id сообщения из сохранённого превью пуша (fallback для «Прочитано»).
  static Future<int?> newestStoredMessageId(int threadId) async {
    final lines = await _loadStored(threadId);
    var maxId = 0;
    for (final line in lines) {
      final id = line.messageId ?? 0;
      if (id > maxId) maxId = id;
    }
    return maxId > 0 ? maxId : null;
  }

  static Future<void> recordOutgoing(int threadId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final line = ChatPushPreviewLine(
      messageId: -DateTime.now().millisecondsSinceEpoch,
      sender: '',
      text: trimmed,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    var lines = await _loadStored(threadId);
    lines = _appendLine(lines, line);
    lines = _trimLines(lines);
    await _saveStored(threadId, lines);
  }

  static Future<ChatPushThreadPreview> build({
    required int threadId,
    required Map<String, dynamic> data,
    String? pushTitle,
    String? pushBody,
    bool enrichFromDatabase = false,
  }) async {
    final incoming = lineFromPushData(
      data: data,
      title: pushTitle,
      body: pushBody,
    );
    var lines = await _loadStored(threadId);
    if (incoming != null) {
      lines = _appendLine(lines, incoming);
      await _saveStored(threadId, lines);
    }

    if (enrichFromDatabase && ChatLocalStore.isSupported) {
      final fromDb = await _linesFromDatabase(threadId, data);
      if (fromDb.isNotEmpty) {
        lines = _mergeDbAndStored(lines, fromDb);
        await _saveStored(threadId, lines);
      }
    }

    final unreadCount = await _effectiveUnreadCount(threadId, data);
    lines = _filterToUnreadLines(lines, unreadCount);
    lines = _trimLines(lines);
    final isGroup = isGroupThread(data);
    final threadTitle = data['thread_title']?.toString().trim() ?? '';
    final title = _notificationTitle(
      isGroup: isGroup,
      threadTitle: threadTitle,
      pushTitle: pushTitle ?? data['title']?.toString(),
      lines: lines,
    );
    final collapsedBody = _collapsedBody(lines, isGroup: isGroup);
    final expandedBody = _expandedBody(lines, isGroup: isGroup);

    return ChatPushThreadPreview(
      title: title,
      collapsedBody: collapsedBody,
      expandedBody: expandedBody,
      isGroup: isGroup,
      lines: lines,
    );
  }

  @visibleForTesting
  static ChatPushPreviewLine? lineFromPushData({
    required Map<String, dynamic> data,
    String? title,
    String? body,
  }) {
    var previewBody = (body ?? data['body']?.toString() ?? '').trim();
    if (previewBody.isEmpty) return null;

    final messageId = chatAsInt(data['message_id']);
    final threadTitle = data['thread_title']?.toString().trim() ?? '';
    final pushTitle = (title ?? data['title']?.toString() ?? '').trim();
    final isGroup = isGroupThread(data);

    var sender = data['sender_name']?.toString().trim() ?? '';
    if (sender.isEmpty && isGroup) {
      if (pushTitle.isNotEmpty && pushTitle != threadTitle) {
        sender = pushTitle;
      } else {
        final split = _splitSenderPrefix(previewBody);
        if (split != null) {
          sender = split.$1;
          previewBody = split.$2;
        }
      }
    }

    return ChatPushPreviewLine(
      messageId: messageId,
      sender: sender,
      text: previewBody,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static (String, String)? _splitSenderPrefix(String body) {
    final colon = body.indexOf(': ');
    if (colon <= 0 || colon > 40) return null;
    final prefix = body.substring(0, colon).trim();
    if (prefix.isEmpty || prefix.contains('\n')) return null;
    final rest = body.substring(colon + 2).trim();
    if (rest.isEmpty) return null;
    return (prefix, rest);
  }

  static Future<int> _threadUnreadCount(int threadId) async {
    if (!ChatLocalStore.isSupported) return 0;
    final thread = await ChatLocalReads.threadById(threadId);
    return chatAsInt(thread?['unread_count']) ?? 0;
  }

  /// unread_count в SQLite может отставать от только что пришедшего push.
  static Future<int> _effectiveUnreadCount(
    int threadId,
    Map<String, dynamic> data,
  ) async {
    var unread = await _threadUnreadCount(threadId);
    final pushMessageId = chatAsInt(data['message_id']);
    if (pushMessageId != null && pushMessageId > 0) {
      unread = unread < 1 ? 1 : unread;
    }
    return unread;
  }

  static bool _isOutgoingPreviewLine(ChatPushPreviewLine line) {
    final id = line.messageId ?? 0;
    return id < 0;
  }

  static List<ChatPushPreviewLine> _mergeDbAndStored(
    List<ChatPushPreviewLine> stored,
    List<ChatPushPreviewLine> fromDb,
  ) {
    final outgoing =
        stored.where(_isOutgoingPreviewLine).toList(growable: false);
    if (outgoing.isEmpty) return fromDb;
    return _appendLines(fromDb, outgoing);
  }

  static List<ChatPushPreviewLine> _appendLines(
    List<ChatPushPreviewLine> base,
    List<ChatPushPreviewLine> extra,
  ) {
    var out = List<ChatPushPreviewLine>.from(base);
    for (final line in extra) {
      out = _appendLine(out, line);
    }
    return out;
  }

  @visibleForTesting
  static List<ChatPushPreviewLine> filterToUnreadLines(
    List<ChatPushPreviewLine> lines,
    int unreadCount,
  ) =>
      _filterToUnreadLines(lines, unreadCount);

  static List<ChatPushPreviewLine> _filterToUnreadLines(
    List<ChatPushPreviewLine> lines,
    int unreadCount,
  ) {
    if (lines.isEmpty) return lines;

    final outgoing =
        lines.where(_isOutgoingPreviewLine).toList(growable: false);
    final incoming =
        lines.where((line) => !_isOutgoingPreviewLine(line)).toList();

    List<ChatPushPreviewLine> unreadIncoming;
    if (unreadCount <= 0) {
      unreadIncoming =
          incoming.isEmpty ? const [] : [incoming.last];
    } else if (incoming.length <= unreadCount) {
      unreadIncoming = incoming;
    } else {
      unreadIncoming = incoming.sublist(incoming.length - unreadCount);
    }

    if (outgoing.isEmpty) return unreadIncoming;
    return _trimLines([...unreadIncoming, ...outgoing]);
  }

  static Future<List<ChatPushPreviewLine>> _linesFromDatabase(
    int threadId,
    Map<String, dynamic> data,
  ) async {
    try {
      final db = await ChatLocalStore.instance.ensureOpen();
      if (db == null) return const [];

      final unreadCount = await _effectiveUnreadCount(threadId, data);
      if (unreadCount <= 0) return const [];

      final isGroup = isGroupThread(data);
      final tail = await ChatLocalStore.instance.readMessagesTail(
        threadId,
        limit: unreadCount + 6,
      );
      final incoming = <ChatPushPreviewLine>[];
      for (final message in tail) {
        if (message['is_system'] == true) continue;
        if (message['is_mine'] == true) continue;
        final text = chatMessagePreviewText(message);
        if (text.isEmpty) continue;
        incoming.add(
          ChatPushPreviewLine(
            messageId: chatAsInt(message['id']),
            sender: isGroup
                ? (message['sender_name']?.toString().trim() ?? '')
                : '',
            text: text,
            timestampMs: _messageTimestampMs(message),
          ),
        );
      }
      if (incoming.length > unreadCount) {
        return incoming.sublist(incoming.length - unreadCount);
      }
      return incoming;
    } catch (e) {
      debugPrint('[ChatPushPreview] sqlite enrich failed: $e');
      return const [];
    }
  }

  static int _messageTimestampMs(Map<String, dynamic> message) {
    final direct = chatAsInt(message['created_at_ms']);
    if (direct != null) return direct;
    final parsed = DateTime.tryParse(message['created_at']?.toString() ?? '');
    return parsed?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
  }

  static Future<List<ChatPushPreviewLine>> _loadStored(int threadId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey(threadId));
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => ChatPushPreviewLine.fromJson(
                e.map((key, value) => MapEntry('$key', value)),
              ))
          .toList();
    } catch (e) {
      debugPrint('[ChatPushPreview] load failed: $e');
      return const [];
    }
  }

  static Future<void> _saveStored(
    int threadId,
    List<ChatPushPreviewLine> lines,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey(threadId),
        jsonEncode(lines.map((line) => line.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[ChatPushPreview] save failed: $e');
    }
  }

  static List<ChatPushPreviewLine> _appendLine(
    List<ChatPushPreviewLine> lines,
    ChatPushPreviewLine incoming,
  ) {
    final out = List<ChatPushPreviewLine>.from(lines);
    if (incoming.messageId != null) {
      final duplicate = out.indexWhere(
        (line) => line.messageId == incoming.messageId,
      );
      if (duplicate >= 0) {
        out[duplicate] = incoming;
        return out;
      }
    }
    out.add(incoming);
    out.sort((a, b) {
      final aId = a.messageId ?? 0;
      final bId = b.messageId ?? 0;
      if (aId != bId) return aId.compareTo(bId);
      final aTs = a.timestampMs ?? 0;
      final bTs = b.timestampMs ?? 0;
      return aTs.compareTo(bTs);
    });
    return out;
  }

  @visibleForTesting
  static List<ChatPushPreviewLine> trimLines(List<ChatPushPreviewLine> lines) =>
      _trimLines(lines);

  static List<ChatPushPreviewLine> _trimLines(List<ChatPushPreviewLine> lines) {
    var out = List<ChatPushPreviewLine>.from(lines);
    if (out.length > maxMessages) {
      out = out.sublist(out.length - maxMessages);
    }
    while (out.isNotEmpty && _totalChars(out) > maxTotalChars) {
      out = out.sublist(1);
    }
    return out;
  }

  static int _totalChars(List<ChatPushPreviewLine> lines) {
    var total = 0;
    for (final line in lines) {
      total += line.text.length;
      if (line.sender.isNotEmpty) total += line.sender.length + 2;
      total += 1;
    }
    return total;
  }

  static String _notificationTitle({
    required bool isGroup,
    required String threadTitle,
    required String? pushTitle,
    required List<ChatPushPreviewLine> lines,
  }) {
    if (isGroup) {
      if (threadTitle.isNotEmpty) return threadTitle;
      final fromPush = pushTitle?.trim() ?? '';
      if (fromPush.isNotEmpty) return fromPush;
      return 'Family Space';
    }
    if (threadTitle.isNotEmpty) return threadTitle;
    final fromPush = pushTitle?.trim() ?? '';
    if (fromPush.isNotEmpty) return fromPush;
    if (lines.isNotEmpty && lines.last.sender.isNotEmpty) {
      return lines.last.sender;
    }
    return 'Family Space';
  }

  static String _collapsedBody(
    List<ChatPushPreviewLine> lines, {
    required bool isGroup,
  }) {
    if (lines.isEmpty) return 'Новое сообщение';
    final last = lines.last;
    if (isGroup && last.sender.isNotEmpty) {
      return '${last.sender}: ${last.text}';
    }
    return last.text;
  }

  static String _expandedBody(
    List<ChatPushPreviewLine> lines, {
    required bool isGroup,
  }) {
    if (lines.isEmpty) return 'Новое сообщение';
    return lines
        .map((line) {
          if (isGroup && line.sender.isNotEmpty) {
            return '${line.sender}: ${line.text}';
          }
          return line.text;
        })
        .join('\n');
  }
}
