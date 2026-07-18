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

/// Стабильная сериализация вложенных map/list (порядок ключей не влияет).
Object? _stableJsonFingerprint(dynamic value) {
  if (value == null) return null;
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return [
      for (final key in keys) [key, _stableJsonFingerprint(value[key])],
    ];
  }
  if (value is List) {
    return [for (final item in value) _stableJsonFingerprint(item)];
  }
  if (value is num && value is! int && value == value.roundToDouble()) {
    return value.toInt();
  }
  return value;
}

/// Поля, которые влияют на отрисовку пузыря/баннера (звонки в metadata.kind=call).
Object? _chatMessageDisplayFingerprint(Map<String, dynamic> message) {
  final attachments = chatAttachmentsOf(message)
      .map((a) => [chatAsInt(a['id']), a['kind'], a['file_url'], a['filename']])
      .toList();
  return [
    chatAsInt(message['id']),
    message['body']?.toString() ?? '',
    message['is_system'] == true,
    message['edited_at']?.toString() ?? '',
    message['read_status']?.toString() ?? '',
    message['sender_user_id'],
    message['sender_name']?.toString() ?? '',
    message['sender_avatar_url']?.toString() ?? '',
    _stableJsonFingerprint(message['metadata']),
    _stableJsonFingerprint(message['reactions']),
    _stableJsonFingerprint(message['reply_to']),
    _stableJsonFingerprint(message['forward']),
    attachments,
    message['_pending'] == true,
    message['_scheduled'] == true,
    message['schedule_id']?.toString() ?? '',
  ];
}

bool chatMessageDisplayEquals(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  return _chatMessageDisplayFingerprint(a).toString() ==
      _chatMessageDisplayFingerprint(b).toString();
}

/// true, если списки дают одинаковую картинку (порядок + контент пузырей).
bool chatMessageListsDisplayEqual(
  List<Map<String, dynamic>> a,
  List<Map<String, dynamic>> b,
) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!chatMessageDisplayEquals(a[i], b[i])) return false;
  }
  return true;
}

int? chatNewestServerMessageId(List<Map<String, dynamic>> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final id = chatAsInt(messages[i]['id']);
    if (id != null && id > 0 && !chatMessageIsPending(messages[i])) {
      return id;
    }
  }
  return null;
}
