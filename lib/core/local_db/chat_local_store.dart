import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_database.dart';
import 'chat_database_connection.dart';
import 'chat_json_migrator.dart';

/// Native SQLite facade for chat threads/messages. Web: unsupported.
class ChatLocalStore {
  ChatLocalStore._();

  static final ChatLocalStore instance = ChatLocalStore._();

  ChatDatabase? _db;
  Future<ChatDatabase?>? _opening;
  bool _started = false;

  static bool get isSupported => ChatDatabase.isSupported;

  Future<ChatDatabase?> ensureOpen() async {
    if (!isSupported) return null;
    if (_db != null) return _db;
    if (_opening != null) return _opening;
    _opening = _open();
    try {
      return await _opening;
    } finally {
      _opening = null;
    }
  }

  Future<ChatDatabase?> _open() async {
    try {
      final db = ChatDatabase();
      await ChatJsonMigrator.migrateIfNeeded(db);
      _db = db;
      _started = true;
      return db;
    } catch (e, st) {
      debugPrint('[ChatLocalStore] open failed: $e\n$st');
      return null;
    }
  }

  /// Open with an explicit executor (FCM background isolate).
  Future<ChatDatabase?> openWithExecutor() async {
    if (!isSupported) return null;
    try {
      final db = ChatDatabase.executor(openChatDatabaseConnection());
      await ChatJsonMigrator.migrateIfNeeded(db);
      return db;
    } catch (e, st) {
      debugPrint('[ChatLocalStore] background open failed: $e\n$st');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> readThreads() async {
    final db = await ensureOpen();
    if (db == null) return const [];
    return db.readThreads();
  }

  Stream<List<Map<String, dynamic>>> watchThreads() async* {
    final db = await ensureOpen();
    if (db == null) {
      yield const [];
      return;
    }
    yield* db.watchThreads();
  }

  Future<List<Map<String, dynamic>>> readMembers() async {
    final db = await ensureOpen();
    if (db == null) return const [];
    return db.readMembers();
  }

  Stream<List<Map<String, dynamic>>> watchMembers() async* {
    final db = await ensureOpen();
    if (db == null) {
      yield const [];
      return;
    }
    yield* db.watchMembers();
  }

  Future<List<Map<String, dynamic>>> readMessages(int threadId) async {
    final db = await ensureOpen();
    if (db == null) return const [];
    return db.readMessages(threadId);
  }

  Stream<List<Map<String, dynamic>>> watchMessages(int threadId) async* {
    final db = await ensureOpen();
    if (db == null) {
      yield const [];
      return;
    }
    yield* db.watchMessages(threadId);
  }

  Future<void> upsertThread(Map<String, dynamic> thread) async {
    final db = await ensureOpen();
    await db?.upsertThread(thread);
  }

  Future<void> replaceThreads(List<Map<String, dynamic>> threads) async {
    final db = await ensureOpen();
    await db?.replaceThreads(threads);
  }

  Future<void> replaceMembers(List<Map<String, dynamic>> members) async {
    final db = await ensureOpen();
    await db?.replaceMembers(members);
  }

  Future<void> upsertMessage(Map<String, dynamic> message) async {
    final db = await ensureOpen();
    await db?.upsertMessage(message);
  }

  Future<void> upsertMessages(
    int threadId,
    List<Map<String, dynamic>> messages,
  ) async {
    final db = await ensureOpen();
    await db?.upsertMessages(threadId, messages);
  }

  Future<void> deleteMessages(int threadId, List<int> messageIds) async {
    final db = await ensureOpen();
    await db?.deleteMessages(threadId, messageIds);
  }

  Future<void> markMessagesRead(int threadId, List<int> messageIds) async {
    final db = await ensureOpen();
    await db?.markMessagesRead(threadId, messageIds);
  }

  Future<void> patchMessageFields(
    int threadId,
    int messageId,
    Map<String, dynamic> patch,
  ) async {
    final db = await ensureOpen();
    await db?.patchMessageFields(threadId, messageId, patch);
  }

  Future<void> clearPendingForThread(int threadId) async {
    final db = await ensureOpen();
    await db?.clearPendingForThread(threadId);
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _started = false;
    await db?.close();
  }

  bool get isStarted => _started;
}