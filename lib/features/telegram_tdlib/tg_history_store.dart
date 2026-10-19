import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/local_db/chat_database.dart';
import '../../core/local_db/chat_local_store.dart';
import 'tdlib_transcript_cache.dart';
import 'telegram_tdlib_service.dart' show TdlibMessage;

/// SQLite-first TG transcript writer/reader (separate tables from FC).
///
/// UI watches tip/window; TDLib live stays for send/media/search/typing.
///
/// Tip/older network fills are invoked by the service/UI via [loadTip]/[loadOlder]
/// callbacks so this file does not import [TelegramTdlibService] (cycle).
class TgHistoryStore {
  TgHistoryStore._();

  static final TgHistoryStore instance = TgHistoryStore._();

  static const tipPaintCap = 20;
  static const ensureTipMin = 16;
  static const olderPageSize = 40;
  static const softCapDmGroup = 400;
  static const softCapChannel = 200;
  static const softCapGlobal = 8000;

  final Set<int> _migratedChats = {};
  final Map<int, Future<int>> _migrateInflight = {};
  final Set<int> _ensureTipInflight = {};
  final Set<String> _ensureOlderInflight = {};

  Future<void> upsertMessages(
    int chatId,
    List<TdlibMessage> messages, {
    String? chatType,
    String? title,
  }) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return;
    if (messages.isEmpty) return;
    try {
      final rows = <({int messageId, int dateMs, String payloadJson})>[];
      for (final m in messages) {
        if (m.id <= 0) continue;
        final json = TdlibTranscriptCache.messageToCacheJson(m);
        rows.add((
          messageId: m.id,
          dateMs: m.date > 0 ? m.date * 1000 : 0,
          payloadJson: jsonEncode(json),
        ));
      }
      if (rows.isEmpty) return;
      await ChatLocalStore.instance.upsertTgMessages(chatId, rows);
      if (chatType != null || title != null) {
        await ChatLocalStore.instance.upsertTgChatState(
          chatId: chatId,
          chatType: chatType,
          title: title,
        );
      }
      unawaited(_evictAfterWrite(chatId, chatType: chatType));
    } catch (e, st) {
      debugPrint('[tg-db] upsert chat=$chatId failed: $e\n$st');
    }
  }

  Future<void> upsertMessage(
    TdlibMessage message, {
    String? chatType,
    String? title,
  }) {
    return upsertMessages(
      message.chatId,
      [message],
      chatType: chatType,
      title: title,
    );
  }

  Future<void> deleteMessages(int chatId, List<int> messageIds) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return;
    if (messageIds.isEmpty) return;
    try {
      await ChatLocalStore.instance.deleteTgMessages(chatId, messageIds);
      debugPrint('[tg-db] delete chat=$chatId n=${messageIds.length}');
    } catch (e) {
      debugPrint('[tg-db] delete chat=$chatId failed: $e');
    }
  }

  Future<void> markHistoryCompleteOlder(int chatId, bool complete) {
    return ChatLocalStore.instance.upsertTgChatState(
      chatId: chatId,
      historyCompleteOlder: complete,
    );
  }

  Future<List<TdlibMessage>> readTail(
    int chatId, {
    int limit = tipPaintCap,
  }) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return const [];
    try {
      final rows = await ChatLocalStore.instance.readTgMessagesTail(
        chatId,
        limit: limit,
      );
      return _decodeRows(rows);
    } catch (e) {
      debugPrint('[tg-db] readTail chat=$chatId failed: $e');
      return const [];
    }
  }

  Future<List<TdlibMessage>> readOlder(
    int chatId, {
    required int beforeMessageId,
    int limit = olderPageSize,
  }) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return const [];
    try {
      final rows = await ChatLocalStore.instance.readTgMessagesOlder(
        chatId,
        beforeMessageId: beforeMessageId,
        limit: limit,
      );
      return _decodeRows(rows);
    } catch (e) {
      debugPrint('[tg-db] readOlder chat=$chatId failed: $e');
      return const [];
    }
  }

  Future<int> count(int chatId) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return 0;
    return ChatLocalStore.instance.countTgMessages(chatId);
  }

  Stream<List<TdlibMessage>> watchChat(int chatId) async* {
    if (kIsWeb || !ChatLocalStore.isSupported) {
      yield const [];
      return;
    }
    await ChatLocalStore.instance.ensureOpen();
    yield* ChatLocalStore.instance.watchTgMessages(chatId).map(_decodeRows);
  }

  /// One-shot meta→rows migrate from [TdlibTranscriptCache].
  /// Single-flight per chat — open UI + openChat used to race two migrates and
  /// pin the isolate ~3s (Шарий tip-seed FRAME total≈3078ms).
  Future<int> migrateFromTranscriptCacheIfNeeded(int chatId) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return 0;
    if (_migratedChats.contains(chatId)) {
      return count(chatId);
    }
    final pending = _migrateInflight[chatId];
    if (pending != null) return pending;
    final run = _migrateFromTranscriptCacheOnce(chatId);
    _migrateInflight[chatId] = run;
    try {
      return await run;
    } finally {
      _migrateInflight.remove(chatId);
    }
  }

  Future<int> _migrateFromTranscriptCacheOnce(int chatId) async {
    try {
      final existing = await count(chatId);
      if (existing >= ensureTipMin) {
        _migratedChats.add(chatId);
        return existing;
      }
      final cached = await TdlibTranscriptCache.read(chatId);
      if (cached.isEmpty) {
        _migratedChats.add(chatId);
        return existing;
      }
      await upsertMessages(chatId, cached);
      _migratedChats.add(chatId);
      final now = await count(chatId);
      debugPrint(
        '[tg-db] migrate chat=$chatId from-cache=${cached.length} now=$now',
      );
      return now;
    } catch (e) {
      debugPrint('[tg-db] migrate chat=$chatId failed: $e');
      return 0;
    }
  }

  /// Fill tip when DB tail is thin. [loadTip] should call TDLib history → upsert.
  Future<void> ensureTip(
    int chatId, {
    int minCount = ensureTipMin,
    String? chatType,
    String? title,
    required Future<void> Function() loadTip,
  }) async {
    if (_ensureTipInflight.contains(chatId)) return;
    _ensureTipInflight.add(chatId);
    try {
      await migrateFromTranscriptCacheIfNeeded(chatId);
      final have = await count(chatId);
      if (have >= minCount) {
        debugPrint('[tg-db] tip chat=$chatId have=$have skip');
        return;
      }
      debugPrint('[tg-db] tip ensure chat=$chatId have=$have min=$minCount');
      await ChatLocalStore.instance.upsertTgChatState(
        chatId: chatId,
        chatType: chatType,
        title: title,
      );
      await loadTip();
      final after = await count(chatId);
      debugPrint('[tg-db] tip done chat=$chatId now=$after');
    } catch (e) {
      debugPrint('[tg-db] tip chat=$chatId failed: $e');
    } finally {
      _ensureTipInflight.remove(chatId);
    }
  }

  /// Scroll-up miss: fetch older page into SQLite via [loadOlder].
  Future<int> ensureOlder(
    int chatId, {
    required int beforeMessageId,
    int pageSize = olderPageSize,
    required Future<int> Function() loadOlder,
  }) async {
    final key = '$chatId:$beforeMessageId';
    if (_ensureOlderInflight.contains(key)) return 0;
    _ensureOlderInflight.add(key);
    try {
      final local = await readOlder(
        chatId,
        beforeMessageId: beforeMessageId,
        limit: pageSize,
      );
      if (local.length >= (pageSize ~/ 2)) {
        debugPrint(
          '[tg-db] older hit-db chat=$chatId before=$beforeMessageId '
          'n=${local.length}',
        );
        return local.length;
      }
      debugPrint(
        '[tg-db] older fetch chat=$chatId before=$beforeMessageId',
      );
      final added = await loadOlder();
      if (added <= 0) {
        final state = await ChatLocalStore.instance.readTgChatState(chatId);
        if (state?.historyCompleteOlder != true) {
          await markHistoryCompleteOlder(chatId, true);
        }
      }
      debugPrint('[tg-db] older done chat=$chatId added=$added');
      return added;
    } catch (e) {
      debugPrint('[tg-db] older chat=$chatId failed: $e');
      return 0;
    } finally {
      _ensureOlderInflight.remove(key);
    }
  }

  Future<void> _evictAfterWrite(int chatId, {String? chatType}) async {
    try {
      final type = chatType ??
          (await ChatLocalStore.instance.readTgChatState(chatId))?.chatType ??
          'unknown';
      final cap = type == 'channel' ? softCapChannel : softCapDmGroup;
      final dropped = await ChatLocalStore.instance.evictTgChatOverCap(
        chatId,
        cap,
      );
      if (dropped > 0) {
        debugPrint('[tg-db] evict chat=$chatId dropped=$dropped cap=$cap');
      }
      final global = await ChatLocalStore.instance.evictTgMessagesGlobal(
        softCapGlobal,
      );
      if (global > 0) {
        debugPrint('[tg-db] evict global dropped=$global');
      }
    } catch (e) {
      debugPrint('[tg-db] evict failed: $e');
    }
  }

  static String chatTypeLabel({
    required bool isChannel,
    required bool isPrivate,
    required bool isGroup,
  }) {
    if (isChannel) return 'channel';
    if (isPrivate) return 'dm';
    if (isGroup) return 'group';
    return 'unknown';
  }

  static List<TdlibMessage> _decodeRows(List<TgMessageRow> rows) {
    final out = <TdlibMessage>[];
    for (final row in rows) {
      if (row.payloadJson.isEmpty) continue;
      try {
        final decoded = jsonDecode(row.payloadJson);
        if (decoded is! Map) continue;
        final m = TdlibTranscriptCache.messageFromCacheJson(
          Map<String, dynamic>.from(decoded),
        );
        if (m != null) out.add(m);
      } catch (_) {}
    }
    return out;
  }
}
