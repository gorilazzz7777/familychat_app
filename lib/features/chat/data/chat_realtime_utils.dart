/// Нормализация JSON из WebSocket (числа, вложенные map/list).
int? chatAsInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

List<int> chatAsIntList(dynamic value) {
  if (value is! List) return [];
  return value.map(chatAsInt).whereType<int>().toList();
}

Map<String, dynamic> chatNormalizeMap(Map<dynamic, dynamic> map) {
  return map.map(
    (key, value) => MapEntry(key.toString(), chatNormalizeValue(value)),
  );
}

dynamic chatNormalizeValue(dynamic value) {
  if (value is Map) return chatNormalizeMap(Map<dynamic, dynamic>.from(value));
  if (value is List) return value.map(chatNormalizeValue).toList();
  if (value is num && value is! int && value == value.roundToDouble()) {
    return value.toInt();
  }
  return value;
}

List<Map<String, dynamic>> chatAttachmentsOf(Map<String, dynamic> message) {
  final raw = message['attachments'];
  if (raw is! List) return [];
  return raw
      .map((item) {
        if (item is! Map) return null;
        return chatNormalizeMap(Map<dynamic, dynamic>.from(item));
      })
      .whereType<Map<String, dynamic>>()
      .toList();
}

bool chatMessageIsPending(Map<String, dynamic> message) {
  final id = chatAsInt(message['id']);
  return message['_pending'] == true ||
      message['read_status'] == 'queued' ||
      message['read_status'] == 'sending' ||
      id == null ||
      id <= 0;
}

int _chatMessageSortKey(Map<String, dynamic> message) {
  final id = chatAsInt(message['id']);
  if (id != null && id > 0 && !chatMessageIsPending(message)) {
    return id;
  }
  final created = DateTime.tryParse(message['created_at']?.toString() ?? '');
  if (created != null) {
  // Pending/optimistic messages sort after confirmed ids by timestamp.
    return 2000000000 + created.millisecondsSinceEpoch;
  }
  return id ?? 0;
}

/// Стабильный порядок ленты: по id сервера, optimistic — по времени в конце.
List<Map<String, dynamic>> sortChatMessages(
  List<Map<String, dynamic>> messages,
) {
  final sorted = List<Map<String, dynamic>>.from(messages);
  sorted.sort(
    (a, b) => _chatMessageSortKey(a).compareTo(_chatMessageSortKey(b)),
  );
  return sorted;
}

List<Map<String, dynamic>> chatUpsertMessage(
  List<Map<String, dynamic>> messages,
  Map<String, dynamic> message,
) {
  final id = chatAsInt(message['id']);
  final next = messages
      .where((m) => id == null || chatAsInt(m['id']) != id)
      .toList();
  next.add(message);
  return sortChatMessages(next);
}

List<Map<String, dynamic>> chatMergeMessageLists(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> incoming,
) {
  final byId = <int, Map<String, dynamic>>{};
  final pending = <Map<String, dynamic>>[];

  void absorb(Map<String, dynamic> message) {
    final id = chatAsInt(message['id']);
    if (id != null && id > 0 && !chatMessageIsPending(message)) {
      byId[id] = message;
      return;
    }
    pending.add(message);
  }

  for (final message in current) {
    absorb(message);
  }
  for (final message in incoming) {
    absorb(message);
  }

  return sortChatMessages([...byId.values, ...pending]);
}
