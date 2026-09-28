import 'dart:async';

import 'package:flutter/foundation.dart';

import '../familychat/data/familychat_repository.dart';
import 'telegram_tdlib_service.dart';

/// Merge Telegram Saved Messages → FC «Избранное» (one-way TG→FC).
///
/// FC notes stay private — never mirrored back to Telegram.
class TelegramSavedBridge {
  TelegramSavedBridge._();
  static final instance = TelegramSavedBridge._();

  FamilyChatRepository? _repo;
  int? _tgChatId;
  int? _fcThreadId;
  bool _hooked = false;
  bool _syncing = false;
  bool _linked = false;

  void bindRepository(FamilyChatRepository repo) {
    _repo = repo;
  }

  void registerLink({required int threadId, required int tgChatId}) {
    if (threadId <= 0 || tgChatId == 0) return;
    _fcThreadId = threadId;
    _tgChatId = tgChatId;
    _linked = true;
    _ensureHook();
  }

  /// Remember link from hub thread payload (`kind=saved` + `telegram`).
  void syncFromThreads(List<Map<String, dynamic>> threads) {
    for (final t in threads) {
      if (t['kind']?.toString() != 'saved') continue;
      final threadId = (t['id'] as num?)?.toInt() ??
          int.tryParse('${t['id'] ?? ''}') ??
          0;
      final tg = t['telegram'];
      if (tg is! Map) continue;
      if (tg['linked'] != true && tg['saved_messages'] != true) continue;
      final tgChatId = (tg['tg_chat_id'] as num?)?.toInt() ??
          int.tryParse('${tg['tg_chat_id'] ?? ''}') ??
          0;
      if (threadId > 0 && tgChatId != 0) {
        registerLink(threadId: threadId, tgChatId: tgChatId);
      }
    }
  }

  void _ensureHook() {
    if (_hooked) return;
    _hooked = true;
    TelegramTdlibService.instance.addBridgeNewMessageListener(_onTdlibMessage);
    TelegramTdlibService.instance.addListener(_onTdlibChanged);
  }

  void _onTdlibChanged() {
    if (TelegramTdlibService.instance.isReady) {
      unawaited(ensureLinkedAndSync());
    }
  }

  void _onTdlibMessage(TdlibMessage msg) {
    if (msg.isService) return;
    final tgChatId = _tgChatId;
    if (tgChatId == null || msg.chatId != tgChatId) return;
    // Saved Messages messages are outgoing (chat-with-self) — still ingest.
    final text = msg.text.trim();
    if (text.isEmpty) return; // media MVP later
    final repo = _repo;
    if (repo == null) return;
    unawaited(() async {
      try {
        await repo.ingestTelegramSavedMessage(
          tgChatId: msg.chatId,
          tgMessageId: msg.id,
          text: text,
          dateUnix: msg.date,
        );
      } catch (e) {
        debugPrint('[saved-bridge] ingest failed: $e');
      }
    }());
  }

  /// Link Saved Messages ↔ Избранное and pull recent TG history (TG→FC only).
  Future<void> ensureLinkedAndSync() async {
    if (_syncing) return;
    final svc = TelegramTdlibService.instance;
    final repo = _repo;
    if (!svc.isReady || repo == null) return;
    _syncing = true;
    try {
      _ensureHook();
      final tgChatId = await svc.ensureSavedMessagesChatId();
      if (tgChatId == null || tgChatId == 0) return;
      _tgChatId = tgChatId;

      final link = await repo.linkTelegramSavedMessages(
        tgChatId: tgChatId,
        title: 'Избранное',
      );
      final threadId = (link['thread_id'] as num?)?.toInt() ??
          int.tryParse('${link['thread_id'] ?? ''}') ??
          0;
      if (threadId > 0) _fcThreadId = threadId;
      _linked = true;

      final messages = await svc.fetchRecentChatMessages(tgChatId, limit: 80);
      // Oldest first so FC timeline order matches TG.
      final ordered = [...messages]..sort((a, b) => a.date.compareTo(b.date));
      for (final msg in ordered) {
        if (msg.isService) continue;
        final text = msg.text.trim();
        if (text.isEmpty) continue;
        try {
          await repo.ingestTelegramSavedMessage(
            tgChatId: tgChatId,
            tgMessageId: msg.id,
            text: text,
            dateUnix: msg.date,
          );
        } catch (e) {
          debugPrint('[saved-bridge] history ingest failed: $e');
        }
      }
      debugPrint(
        '[saved-bridge] linked tg=$tgChatId thread=$_fcThreadId '
        'history=${ordered.length} linked=$_linked',
      );
    } catch (e) {
      debugPrint('[saved-bridge] ensureLinkedAndSync failed: $e');
    } finally {
      _syncing = false;
    }
  }
}
