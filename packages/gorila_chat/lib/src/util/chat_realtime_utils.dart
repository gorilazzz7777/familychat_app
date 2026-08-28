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
      message['read_status'] == 'failed' ||
      id == null ||
      id <= 0;
}

/// True when the local viewer sent [message].
///
/// Prefer [is_mine] so ownership survives payloads that omit `sender_user_id`
/// (partial HTTP/WS echoes). Fall back to comparing sender ids.
bool chatMessageIsMine(Map<String, dynamic> message, int? currentUserId) {
  if (message['is_mine'] == true) return true;
  if (currentUserId == null) return false;
  return chatAsInt(message['sender_user_id']) == currentUserId;
}

int? chatSenderUserIdOf(Map<String, dynamic> message) {
  final direct = chatAsInt(message['sender_user_id']);
  if (direct != null) return direct;
  final sender = message['sender'];
  if (sender is Map) {
    return chatAsInt(sender['user_id']) ?? chatAsInt(sender['id']);
  }
  return chatAsInt(message['user_id']);
}

/// Keep / restore ownership fields across optimistic → server merges and
/// incomplete upserts so a sent bubble cannot flip to the peer side.
Map<String, dynamic> chatEnsureMessageOwnership(
  Map<String, dynamic> message, {
  int? currentUserId,
  Map<String, dynamic>? previous,
}) {
  final next = Map<String, dynamic>.from(message);

  final prevSender =
      previous == null ? null : chatSenderUserIdOf(previous);
  var sender = chatSenderUserIdOf(next);
  if (sender == null && prevSender != null) {
    sender = prevSender;
    next['sender_user_id'] = prevSender;
  } else if (sender != null && chatAsInt(next['sender_user_id']) == null) {
    next['sender_user_id'] = sender;
  }

  final prevMine = previous?['is_mine'] == true;
  final mineFlag = next['is_mine'] == true || prevMine;
  if (mineFlag) {
    next['is_mine'] = true;
  }

  if (currentUserId != null) {
    if (mineFlag && chatAsInt(next['sender_user_id']) == null) {
      next['sender_user_id'] = currentUserId;
      sender = currentUserId;
    }
    if (sender == currentUserId) {
      next['is_mine'] = true;
    }
  }

  if (previous != null) {
    for (final key in const [
      'sender_name',
      'sender_avatar_url',
    ]) {
      final incoming = next[key]?.toString().trim() ?? '';
      final prior = previous[key]?.toString().trim() ?? '';
      if (incoming.isEmpty && prior.isNotEmpty) {
        next[key] = previous[key];
      }
    }
  }

  return next;
}

/// True when [pending] is an optimistic/outbox row that already landed as [server].
///
/// Used to drop stuck "sending" duplicates after offline delivery or WS echo.
///
/// Must stay strict: media shares often have empty body + N attachments and would
/// otherwise match an older photo/video from the same user and vanish from the UI.
///
/// Server echo may arrive slightly before local `created_at` (clock / network),
/// but must not match a share that is clearly older than the optimistic row.
const int kChatPendingMatchMaxFutureSkewMs = 90 * 1000;
const int kChatPendingMatchMaxPastSkewMs = 2 * 1000;

bool chatPendingMatchesServer(
  Map<String, dynamic> pending,
  Map<String, dynamic> server, {
  int? currentUserId,
}) {
  if (!chatMessageIsPending(pending) || chatMessageIsPending(server)) {
    return false;
  }
  if (pending['_scheduled'] == true) return false;

  final serverSender = chatSenderUserIdOf(server);
  if (currentUserId != null &&
      serverSender != null &&
      serverSender != currentUserId) {
    return false;
  }
  final pendingSender = chatSenderUserIdOf(pending);
  if (pendingSender != null &&
      serverSender != null &&
      pendingSender != serverSender) {
    return false;
  }

  final pendingCreated =
      DateTime.tryParse(pending['created_at']?.toString() ?? '');
  final serverCreated =
      DateTime.tryParse(server['created_at']?.toString() ?? '');
  if (pendingCreated != null && serverCreated != null) {
    final deltaMs =
        serverCreated.difference(pendingCreated).inMilliseconds;
    // Server older than pending → previous share, not this delivery.
    if (deltaMs < -kChatPendingMatchMaxPastSkewMs) return false;
    // Server too far in the future relative to pending → unrelated.
    if (deltaMs > kChatPendingMatchMaxFutureSkewMs) return false;
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

  if (!_chatPendingAttachmentsMatch(pending, server)) return false;

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

bool _chatPendingAttachmentsMatch(
  Map<String, dynamic> pending,
  Map<String, dynamic> server,
) {
  final pendingAtts = chatAttachmentsOf(pending);
  final serverAtts = chatAttachmentsOf(server);
  if (pendingAtts.length != serverAtts.length) return false;
  if (pendingAtts.isEmpty) return true;

  // Upload-in-flight share: filename may change after compress; match kind only.
  // Directional time in chatPendingMatchesServer blocks older same-shape media.
  final uploading = pendingAtts.any((a) => a['_pending'] == true);

  for (var i = 0; i < pendingAtts.length; i++) {
    final p = pendingAtts[i];
    final s = serverAtts[i];
    final pKind = (p['kind']?.toString() ?? '').trim();
    final sKind = (s['kind']?.toString() ?? '').trim();
    // If optimistic side knows the kind, server must match (empty ≠ wildcard).
    if (pKind.isNotEmpty && pKind != sKind) {
      return false;
    }
    if (uploading) continue;
    final pName = (p['filename']?.toString() ?? '').trim();
    final sName = (s['filename']?.toString() ?? '').trim();
    // Same for filename: missing server name must not match a named pending
    // share (local cache often omits filenames on older rows).
    if (pName.isNotEmpty && pName != sName) {
      return false;
    }
  }
  return true;
}

/// Pending rows from in-memory UI that should be merged back into a SQLite
/// snapshot. Share uploads are always seeded first — if the temp id is gone
/// from SQLite, [replacePending] already finished and reinject would duplicate.
List<Map<String, dynamic>> chatPendingToReinject({
  required List<Map<String, dynamic>> memoryMessages,
  required List<Map<String, dynamic>> sqliteRows,
}) {
  final sqliteIds = <int>{
    for (final row in sqliteRows)
      if (chatAsInt(row['id']) != null) chatAsInt(row['id'])!,
  };
  return [
    for (final message in memoryMessages)
      if (chatMessageIsPending(message) &&
          message['_scheduled'] != true &&
          _shouldReinjectPending(message, sqliteIds))
        message,
  ];
}

bool _shouldReinjectPending(Map<String, dynamic> pending, Set<int> sqliteIds) {
  final id = chatAsInt(pending['id']);
  // Already in the SQLite snapshot — re-adding would duplicate the same id
  // (and GlobalKey) in the ListView.
  if (id != null && sqliteIds.contains(id)) return false;
  if (id == null) return true;
  final uploading =
      chatAttachmentsOf(pending).any((a) => a['_pending'] == true);
  // Share media: seeded before UI; absence means deliver replaced it.
  if (uploading) return false;
  // Text/file optimistic may exist only in memory for one frame before upsert.
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
  final pendingById = <int, Map<String, dynamic>>{};
  final pendingNoId = <Map<String, dynamic>>[];

  void absorb(Map<String, dynamic> message) {
    final id = chatAsInt(message['id']);
    if (id != null && id > 0 && !chatMessageIsPending(message)) {
      byId[id] = message;
      return;
    }
    if (id != null) {
      // Last write wins; never keep two rows with the same id.
      pendingById[id] = message;
      return;
    }
    pendingNoId.add(message);
  }

  for (final message in current) {
    absorb(message);
  }
  for (final message in incoming) {
    absorb(message);
  }

  return chatReconcilePendingDuplicates(
    [...byId.values, ...pendingById.values, ...pendingNoId],
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
    message['is_mine'] == true,
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
