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

/// True when [pending] is an optimistic/outbox row that already landed as [server].
///
/// Used to drop stuck "sending" duplicates after offline delivery or WS echo.
bool chatPendingMatchesServer(
  Map<String, dynamic> pending,
  Map<String, dynamic> server, {
  int? currentUserId,
}) {
  if (!chatMessageIsPending(pending) || chatMessageIsPending(server)) {
    return false;
  }
  if (pending['_scheduled'] == true) return false;

  final serverSender = chatAsInt(server['sender_user_id']);
  if (currentUserId != null &&
      serverSender != null &&
      serverSender != currentUserId) {
    return false;
  }
  final pendingSender = chatAsInt(pending['sender_user_id']);
  if (pendingSender != null &&
      serverSender != null &&
      pendingSender != serverSender) {
    return false;
  }

  final pendingBody = (pending['body']?.toString() ?? '').trim();
  final serverBody = (server['body']?.toString() ?? '').trim();
  if (pendingBody != serverBody) return false;

  final pendingReply = chatAsInt(
    pending['reply_to'] is Map
        ? (pending['reply_to'] as Map)['message_id']
        : null,
  );
  final serverReply = chatAsInt(
    server['reply_to'] is Map
        ? (server['reply_to'] as Map)['message_id']
        : null,
  );
  if (pendingReply != serverReply) return false;

  if (chatAttachmentsOf(pending).length != chatAttachmentsOf(server).length) {
    return false;
  }

  // Location / voice metadata fingerprint (when present on either side).
  final pendingMeta = pending['metadata'];
  final serverMeta = server['metadata'];
  if (pendingMeta is Map || serverMeta is Map) {
    final pLoc = pendingMeta is Map ? pendingMeta['location'] : null;
    final sLoc = serverMeta is Map ? serverMeta['location'] : null;
    if (pLoc != null || sLoc != null) {
      if (_stableJsonFingerprint(pLoc).toString() !=
          _stableJsonFingerprint(sLoc).toString()) {
        return false;
      }
    }
    final pVoice = pendingMeta is Map && pendingMeta['voice'] is Map;
    final sVoice = serverMeta is Map && serverMeta['voice'] is Map;
    if (pVoice != sVoice) return false;
  }

  return true;
}

/// Drop optimistic rows that already exist as confirmed server messages.
List<Map<String, dynamic>> chatReconcilePendingDuplicates(
  List<Map<String, dynamic>> messages, {
  int? currentUserId,
}) {
  final server = <Map<String, dynamic>>[];
  final pending = <Map<String, dynamic>>[];
  for (final message in messages) {
    if (chatMessageIsPending(message) && message['_scheduled'] != true) {
      pending.add(message);
    } else {
      server.add(message);
    }
  }
  if (pending.isEmpty) return sortChatMessages(messages);

  final claimedServerIndexes = <int>{};
  final keptPending = <Map<String, dynamic>>[];

  for (final p in pending) {
    var bestIndex = -1;
    var bestDelta = 1 << 62;
    final pendingCreated =
        DateTime.tryParse(p['created_at']?.toString() ?? '');
    for (var i = 0; i < server.length; i++) {
      if (claimedServerIndexes.contains(i)) continue;
      if (!chatPendingMatchesServer(
        p,
        server[i],
        currentUserId: currentUserId,
      )) {
        continue;
      }
      final serverCreated =
          DateTime.tryParse(server[i]['created_at']?.toString() ?? '');
      var delta = 0;
      if (pendingCreated != null && serverCreated != null) {
        delta = (pendingCreated.difference(serverCreated).inMilliseconds)
            .abs();
      }
      if (bestIndex < 0 || delta < bestDelta) {
        bestIndex = i;
        bestDelta = delta;
      }
    }
    if (bestIndex >= 0) {
      claimedServerIndexes.add(bestIndex);
    } else {
      keptPending.add(p);
    }
  }

  return sortChatMessages([...server, ...keptPending]);
}

int _chatMessageSortKey(Map<String, dynamic> message) {
  final id = chatAsInt(message['id']);
  if (id != null && id > 0 && !chatMessageIsPending(message)) {
    return id;
  }
  final created = DateTime.tryParse(message['created_at']?.toString() ?? '');
  if (created != null) {
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
  List<Map<String, dynamic>> incoming, {
  int? currentUserId,
}) {
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

  return chatReconcilePendingDuplicates(
    [...byId.values, ...pending],
    currentUserId: currentUserId,
  );
}

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

bool chatMessageBelongsToThread(
  Map<String, dynamic> message,
  int? threadId,
) {
  if (threadId == null) return true;
  return chatAsInt(message['thread_id']) == threadId;
}
