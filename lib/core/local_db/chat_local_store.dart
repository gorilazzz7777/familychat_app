import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'chat_database.dart';
import 'chat_json_migrator.dart';

/// Native SQLite facade for chat threads/messages. Web: unsupported for now.
class ChatLocalStore {
  ChatLocalStore._();

  static final ChatLocalStore instance = ChatLocalStore._();

  ChatDatabase? _db;
  Future<ChatDatabase?>? _opening;
  bool _started = false;
  Future<void> _writeChain = Future<void>.value();

  static bool get isSupported => ChatDatabase.isSupported;

  Future<void> _enqueueWrite(Future<void> Function(ChatDatabase db) op) {
    final done = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        final db = await ensureOpen();
        if (db != null) await op(db);
        if (!done.isCompleted) done.complete();
      } catch (e, st) {
        if (!done.isCompleted) done.completeError(e, st);
      }
    });
    return done.future;
  }

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

  /// Same connection as [ensureOpen]. A second NativeDatabase on this file
  /// is what caused SQLITE_BUSY / "database is locked".
  Future<ChatDatabase?> openWithExecutor() => ensureOpen();

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

  Future<void> upsertThread(Map<String, dynamic> thread) {
    return _enqueueWrite((db) => db.upsertThread(thread));
  }

  Future<void> replaceThreads(List<Map<String, dynamic>> threads) {
    return _enqueueWrite((db) => db.replaceThreads(threads));
  }

  Future<void> replaceMembers(List<Map<String, dynamic>> members) {
    return _enqueueWrite((db) => db.replaceMembers(members));
  }

  Future<void> upsertMessage(Map<String, dynamic> message) {
    return _enqueueWrite((db) => db.upsertMessage(message));
  }

  Future<void> upsertMessages(
    int threadId,
    List<Map<String, dynamic>> messages,
  ) {
    return _enqueueWrite((db) => db.upsertMessages(threadId, messages));
  }

  Future<void> deleteMessages(int threadId, List<int> messageIds) {
    return _enqueueWrite((db) => db.deleteMessages(threadId, messageIds));
  }

  Future<void> deleteMissingFromWindow({
    required int threadId,
    required int minId,
    required int maxId,
    required Set<int> keepIds,
  }) {
    return _enqueueWrite(
      (db) => db.deleteMissingFromWindow(
        threadId: threadId,
        minId: minId,
        maxId: maxId,
        keepIds: keepIds,
      ),
    );
  }

  Future<void> markMessagesRead(int threadId, List<int> messageIds) {
    return _enqueueWrite((db) => db.markMessagesRead(threadId, messageIds));
  }

  Future<void> patchMessageFields(
    int threadId,
    int messageId,
    Map<String, dynamic> patch,
  ) {
    return _enqueueWrite(
      (db) => db.patchMessageFields(threadId, messageId, patch),
    );
  }

  Future<String?> metaGet(String key) async {
    final db = await ensureOpen();
    return db?.metaGet(key);
  }

  Future<void> metaSet(String key, String value) {
    return _enqueueWrite((db) => db.metaSet(key, value));
  }

  Future<List<Map<String, dynamic>>> readOutboxItems() async {
    final db = await ensureOpen();
    if (db == null) return const [];
    return db.readOutboxItems();
  }

  Future<void> writeOutboxItems(List<Map<String, dynamic>> items) {
    return _enqueueWrite((db) => db.writeOutboxItems(items));
  }

  Future<void> saveOutboxBlob(String storageKey, List<int> bytes) {
    return _enqueueWrite(
      (db) => db.saveOutboxBlob(storageKey, Uint8List.fromList(bytes)),
    );
  }

  Future<Uint8List?> readOutboxBlob(String storageKey) async {
    final db = await ensureOpen();
    return db?.readOutboxBlob(storageKey);
  }

  Future<void> deleteOutboxBlob(String storageKey) {
    return _enqueueWrite((db) => db.deleteOutboxBlob(storageKey));
  }

  Future<Map<String, Map<String, dynamic>>> readAllMediaIndex() async {
    final db = await ensureOpen();
    if (db == null) return const {};
    return db.readAllMediaIndex();
  }

  Future<void> upsertMediaIndexRow(
    String key,
    Map<String, dynamic> payload,
  ) {
    return _enqueueWrite((db) => db.upsertMediaIndexRow(key, payload));
  }

  Future<void> deleteMediaIndexRow(String key) {
    return _enqueueWrite((db) => db.deleteMediaIndexRow(key));
  }

  Future<void> replaceAllMediaIndex(
    Map<String, Map<String, dynamic>> all,
  ) {
    return _enqueueWrite((db) => db.replaceAllMediaIndex(all));
  }

  Future<void> clearPendingForThread(int threadId) {
    return _enqueueWrite((db) => db.clearPendingForThread(threadId));
  }

  Future<int?> oldestServerMessageId(int threadId) async {
    final db = await ensureOpen();
    return db?.oldestServerMessageId(threadId);
  }

  Future<int?> newestServerMessageId(int threadId) async {
    final db = await ensureOpen();
    return db?.newestServerMessageId(threadId);
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _started = false;
    await db?.close();
  }

  bool get isStarted => _started;
}