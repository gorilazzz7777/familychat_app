import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'chat_database_connection.dart';
import 'chat_tables.dart';

part 'chat_database.g.dart';

@DriftDatabase(tables: [
  ChatThreadRows,
  ChatMessageRows,
  ChatMemberRows,
  ChatMetaRows,
])
class ChatDatabase extends _$ChatDatabase {
  ChatDatabase() : super(openChatDatabaseConnection());

  /// Separate isolate / FCM background entry.
  ChatDatabase.executor(super.e);

  @override
  int get schemaVersion => 1;

  static const metaMigratedFromJson = 'migrated_json_v1';

  static bool get isSupported => !kIsWeb;

  Future<String?> metaGet(String key) async {
    final row = await (select(chatMetaRows)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> metaSet(String key, String value) async {
    await into(chatMetaRows).insertOnConflictUpdate(
      ChatMetaRowsCompanion.insert(key: key, value: value),
    );
  }

  Future<void> replaceThreads(List<Map<String, dynamic>> threads) async {
    await transaction(() async {
      await delete(chatThreadRows).go();
      for (final thread in threads) {
        await upsertThread(thread);
      }
    });
  }

  Future<void> upsertThread(Map<String, dynamic> thread) async {
    final id = _asInt(thread['id']);
    if (id == null) return;
    final last = thread['last_message'];
    final lastMap = last is Map ? Map<String, dynamic>.from(last) : null;
    final lastId = lastMap == null ? null : _asInt(lastMap['id']);
    final activity = _createdAtMs(lastMap?['created_at']) ??
        _createdAtMs(thread['updated_at']) ??
        0;
    final unread = _asInt(thread['unread_count']) ?? 0;
    await into(chatThreadRows).insertOnConflictUpdate(
      ChatThreadRowsCompanion.insert(
        id: Value(id),
        payloadJson: jsonEncode(thread),
        lastActivityMs: Value(activity),
        unreadCount: Value(unread),
        lastMessageId: Value(lastId),
      ),
    );
  }

  Future<void> replaceMembers(List<Map<String, dynamic>> members) async {
    await transaction(() async {
      await delete(chatMemberRows).go();
      for (final member in members) {
        final userId = _asInt(member['user_id']);
        if (userId == null) continue;
        await into(chatMemberRows).insertOnConflictUpdate(
          ChatMemberRowsCompanion.insert(
            userId: Value(userId),
            payloadJson: jsonEncode(member),
          ),
        );
      }
    });
  }

  Future<void> upsertMessage(Map<String, dynamic> message) async {
    final threadId = _asInt(message['thread_id']);
    final messageId = _asInt(message['id']);
    if (threadId == null || messageId == null) return;
    final pending = message['_pending'] == true ||
        message['read_status'] == 'queued' ||
        messageId <= 0;
    final merged = await _mergePreservedMediaFields(
      threadId: threadId,
      messageId: messageId,
      incoming: message,
    );
    await into(chatMessageRows).insertOnConflictUpdate(
      ChatMessageRowsCompanion.insert(
        threadId: threadId,
        messageId: messageId,
        payloadJson: jsonEncode(merged),
        createdAtMs: Value(_createdAtMs(merged['created_at']) ?? 0),
        isPending: Value(pending),
      ),
    );
  }

  Future<void> upsertMessages(
    int threadId,
    List<Map<String, dynamic>> messages,
  ) async {
    if (messages.isEmpty) return;
    await transaction(() async {
      for (final message in messages) {
        final copy = Map<String, dynamic>.from(message);
        copy['thread_id'] ??= threadId;
        final messageId = _asInt(copy['id']);
        if (messageId == null) continue;
        final pending = copy['_pending'] == true ||
            copy['read_status'] == 'queued' ||
            messageId <= 0;
        final merged = await _mergePreservedMediaFields(
          threadId: threadId,
          messageId: messageId,
          incoming: copy,
        );
        await into(chatMessageRows).insertOnConflictUpdate(
          ChatMessageRowsCompanion.insert(
            threadId: threadId,
            messageId: messageId,
            payloadJson: jsonEncode(merged),
            createdAtMs: Value(_createdAtMs(merged['created_at']) ?? 0),
            isPending: Value(pending),
          ),
        );
      }
    });
  }

  /// Keep pending; replace server rows for this window merge via upsert.
  Future<void> upsertMessageWindow(
    int threadId,
    List<Map<String, dynamic>> messages,
  ) async {
    await upsertMessages(threadId, messages);
  }

  Future<Map<String, dynamic>> _mergePreservedMediaFields({
    required int threadId,
    required int messageId,
    required Map<String, dynamic> incoming,
  }) async {
    final existingRow = await (select(chatMessageRows)
          ..where(
            (t) =>
                t.threadId.equals(threadId) & t.messageId.equals(messageId),
          ))
        .getSingleOrNull();
    if (existingRow == null) return incoming;
    Map<String, dynamic> existing;
    try {
      existing = Map<String, dynamic>.from(
        jsonDecode(existingRow.payloadJson) as Map,
      );
    } catch (_) {
      return incoming;
    }
    final incomingAtts = incoming['attachments'];
    final existingAtts = existing['attachments'];
    if (incomingAtts is! List || existingAtts is! List) return incoming;
    final byId = <int, Map<String, dynamic>>{};
    for (final item in existingAtts) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = _asInt(map['id']);
      if (id == null) continue;
      byId[id] = map;
    }
    const keys = [
      'local_device_path',
      'local_asset_id',
      'local_media_kind',
      'skip_phone_album',
      'server_url',
      '_outgoing_original',
    ];
    final mergedAtts = <dynamic>[];
    for (final item in incomingAtts) {
      if (item is! Map) {
        mergedAtts.add(item);
        continue;
      }
      final map = Map<String, dynamic>.from(item);
      final id = _asInt(map['id']);
      final prev = id == null ? null : byId[id];
      if (prev != null) {
        for (final key in keys) {
          final hasIncoming = map[key] != null && '${map[key]}'.trim().isNotEmpty;
          if (!hasIncoming && prev[key] != null) {
            map[key] = prev[key];
          }
        }
      }
      mergedAtts.add(map);
    }
    incoming['attachments'] = mergedAtts;
    return incoming;
  }

  Future<void> deleteMessages(int threadId, List<int> messageIds) async {
    if (messageIds.isEmpty) return;
    await (delete(chatMessageRows)
          ..where(
            (t) =>
                t.threadId.equals(threadId) & t.messageId.isIn(messageIds),
          ))
        .go();
  }

  Future<void> patchMessageFields(
    int threadId,
    int messageId,
    Map<String, dynamic> patch,
  ) async {
    final row = await (select(chatMessageRows)
          ..where(
            (t) =>
                t.threadId.equals(threadId) & t.messageId.equals(messageId),
          ))
        .getSingleOrNull();
    if (row == null) return;
    final map = jsonDecode(row.payloadJson) as Map<String, dynamic>;
    map.addAll(patch);
    await upsertMessage(map);
  }

  Future<void> markMessagesRead(int threadId, List<int> messageIds) async {
    for (final id in messageIds) {
      await patchMessageFields(threadId, id, {'read_status': 'read'});
    }
  }

  Future<void> clearPendingForThread(int threadId) async {
    await (delete(chatMessageRows)
          ..where(
            (t) => t.threadId.equals(threadId) & t.isPending.equals(true),
          ))
        .go();
  }

  Future<List<Map<String, dynamic>>> readThreads() async {
    final rows = await (select(chatThreadRows)
          ..orderBy([(t) => OrderingTerm.desc(t.lastActivityMs)]))
        .get();
    return rows.map(_decodeThread).toList();
  }

  Stream<List<Map<String, dynamic>>> watchThreads() {
    return (select(chatThreadRows)
          ..orderBy([(t) => OrderingTerm.desc(t.lastActivityMs)]))
        .watch()
        .map((rows) => rows.map(_decodeThread).toList());
  }

  Future<List<Map<String, dynamic>>> readMembers() async {
    final rows = await select(chatMemberRows).get();
    return rows.map(_decodeMember).toList();
  }

  Stream<List<Map<String, dynamic>>> watchMembers() {
    return select(chatMemberRows)
        .watch()
        .map((rows) => rows.map(_decodeMember).toList());
  }

  Future<List<Map<String, dynamic>>> readMessages(int threadId) async {
    final rows = await (select(chatMessageRows)
          ..where((t) => t.threadId.equals(threadId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAtMs),
            (t) => OrderingTerm.asc(t.messageId),
          ]))
        .get();
    return rows.map(_decodeMessage).toList();
  }

  Stream<List<Map<String, dynamic>>> watchMessages(int threadId) {
    return (select(chatMessageRows)
          ..where((t) => t.threadId.equals(threadId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAtMs),
            (t) => OrderingTerm.asc(t.messageId),
          ]))
        .watch()
        .map((rows) => rows.map(_decodeMessage).toList());
  }

  Future<int?> newestServerMessageId(int threadId) async {
    final row = await (select(chatMessageRows)
          ..where(
            (t) =>
                t.threadId.equals(threadId) &
                t.isPending.equals(false) &
                t.messageId.isBiggerThanValue(0),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.messageId)])
          ..limit(1))
        .getSingleOrNull();
    return row?.messageId;
  }

  Future<int?> oldestServerMessageId(int threadId) async {
    final row = await (select(chatMessageRows)
          ..where(
            (t) =>
                t.threadId.equals(threadId) &
                t.isPending.equals(false) &
                t.messageId.isBiggerThanValue(0),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.messageId)])
          ..limit(1))
        .getSingleOrNull();
    return row?.messageId;
  }

  Map<String, dynamic> _decodeThread(ChatThreadRow row) {
    return Map<String, dynamic>.from(jsonDecode(row.payloadJson) as Map);
  }

  Map<String, dynamic> _decodeMember(ChatMemberRow row) {
    return Map<String, dynamic>.from(jsonDecode(row.payloadJson) as Map);
  }

  Map<String, dynamic> _decodeMessage(ChatMessageRow row) {
    return Map<String, dynamic>.from(jsonDecode(row.payloadJson) as Map);
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value');
  }

  static int? _createdAtMs(Object? raw) {
    final dt = DateTime.tryParse(raw?.toString() ?? '');
    return dt?.millisecondsSinceEpoch;
  }
}