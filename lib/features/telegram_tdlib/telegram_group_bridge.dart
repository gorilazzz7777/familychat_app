import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../familychat/data/familychat_repository.dart';
import 'telegram_tdlib_service.dart';

/// Client-side bridge for TDLib-linked FC groups.
///
/// - FC→TG: [mirrorOutboundText] (+ local pending queue when TDLib offline)
/// - TG→FC: listens [TelegramTdlibService.onBridgeNewMessage] → ingest API
class TelegramGroupBridge {
  TelegramGroupBridge._();
  static final instance = TelegramGroupBridge._();

  static const _pendingKey = 'tdlib_group_bridge_pending_v1';

  FamilyChatRepository? _repo;
  final Map<int, int> _tgChatToThread = {}; // tg_chat_id → fc thread_id
  bool _hooked = false;
  bool _flushing = false;

  void bindRepository(FamilyChatRepository repo) {
    _repo = repo;
  }

  /// Remember a linked group so inbound TG updates can be ingested.
  void registerLink({required int threadId, required int tgChatId}) {
    if (threadId <= 0 || tgChatId == 0) return;
    _tgChatToThread[tgChatId] = threadId;
    _ensureHook();
  }

  void unregisterLink({int? threadId, int? tgChatId}) {
    if (tgChatId != null) {
      _tgChatToThread.remove(tgChatId);
    }
    if (threadId != null) {
      _tgChatToThread.removeWhere((_, t) => t == threadId);
    }
  }

  /// Load links from thread list payloads (`telegram.tg_chat_id`).
  void syncFromThreads(List<Map<String, dynamic>> threads) {
    for (final t in threads) {
      if (t['kind']?.toString() != 'group') continue;
      final threadId = (t['id'] as num?)?.toInt() ??
          int.tryParse('${t['id'] ?? ''}') ??
          0;
      final tg = t['telegram'];
      if (tg is! Map) continue;
      if (tg['linked'] != true) continue;
      final mode = tg['bridge_mode']?.toString() ?? 'tdlib';
      if (mode != 'tdlib' && mode != 'secretary') continue;
      final tgChatId = (tg['tg_chat_id'] as num?)?.toInt() ??
          int.tryParse('${tg['tg_chat_id'] ?? ''}') ??
          0;
      if (threadId > 0 && tgChatId != 0) {
        _tgChatToThread[tgChatId] = threadId;
      }
    }
    if (_tgChatToThread.isNotEmpty) _ensureHook();
  }

  void _ensureHook() {
    if (_hooked) return;
    _hooked = true;
    TelegramTdlibService.instance.onBridgeNewMessage = _onTdlibMessage;
    // Flush pending when TDLib becomes ready.
    TelegramTdlibService.instance.addListener(_onTdlibChanged);
  }

  void _onTdlibChanged() {
    if (TelegramTdlibService.instance.isReady) {
      unawaited(flushPending());
    }
  }

  void _onTdlibMessage(TdlibMessage msg) {
    if (msg.isOutgoing) return; // FC→TG echoes registered via outbound-map
    if (msg.isService) return;
    final threadId = _tgChatToThread[msg.chatId];
    if (threadId == null) return;
    final text = msg.text.trim();
    if (text.isEmpty) return; // media MVP later
    final repo = _repo;
    if (repo == null) return;
    unawaited(() async {
      try {
        await repo.ingestTelegramGroupBridgeMessage(
          threadId: threadId,
          tgChatId: msg.chatId,
          tgMessageId: msg.id,
          text: text,
          senderTgUserId: msg.senderUserId,
          isOutgoing: false,
        );
      } catch (e) {
        debugPrint('[group-bridge] ingest failed: $e');
      }
    }());
  }

  /// Mirror an FC text message into the linked Telegram group.
  ///
  /// Never fails the FC send path — queues locally when TDLib is offline.
  Future<void> mirrorOutboundText({
    required int threadId,
    required int tgChatId,
    required int fcMessageId,
    required String text,
  }) async {
    final body = text.trim();
    if (body.isEmpty || threadId <= 0 || tgChatId == 0) return;
    registerLink(threadId: threadId, tgChatId: tgChatId);

    final svc = TelegramTdlibService.instance;
    if (!svc.isReady) {
      await _enqueuePending(
        threadId: threadId,
        tgChatId: tgChatId,
        fcMessageId: fcMessageId,
        text: body,
      );
      return;
    }

    try {
      final tgMsgId = await svc.sendTextReturningId(tgChatId, body);
      if (tgMsgId != null && tgMsgId > 0 && _repo != null) {
        await _repo!.registerTelegramGroupOutboundMap(
          threadId: threadId,
          fcMessageId: fcMessageId,
          tgChatId: tgChatId,
          tgMessageId: tgMsgId,
        );
      }
    } catch (e) {
      debugPrint('[group-bridge] outbound failed, queueing: $e');
      await _enqueuePending(
        threadId: threadId,
        tgChatId: tgChatId,
        fcMessageId: fcMessageId,
        text: body,
      );
    }
  }

  Future<void> _enqueuePending({
    required int threadId,
    required int tgChatId,
    required int fcMessageId,
    required String text,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _readPending(prefs);
    // Dedupe by fc_message_id.
    list.removeWhere(
      (e) => (e['fc_message_id'] as num?)?.toInt() == fcMessageId,
    );
    list.add({
      'thread_id': threadId,
      'tg_chat_id': tgChatId,
      'fc_message_id': fcMessageId,
      'text': text,
      'enqueued_at': DateTime.now().toUtc().toIso8601String(),
      'attempts': 0,
    });
    await prefs.setString(_pendingKey, jsonEncode(list));
  }

  List<Map<String, dynamic>> _readPending(SharedPreferences prefs) {
    final raw = prefs.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final e in decoded)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Retry queued FC→TG delivers when TDLib is online.
  Future<void> flushPending() async {
    if (_flushing) return;
    final svc = TelegramTdlibService.instance;
    if (!svc.isReady) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _readPending(prefs);
      if (list.isEmpty) return;
      final remain = <Map<String, dynamic>>[];
      for (final item in list) {
        final threadId = (item['thread_id'] as num?)?.toInt() ?? 0;
        final tgChatId = (item['tg_chat_id'] as num?)?.toInt() ?? 0;
        final fcMessageId = (item['fc_message_id'] as num?)?.toInt() ?? 0;
        final text = item['text']?.toString() ?? '';
        final attempts = (item['attempts'] as num?)?.toInt() ?? 0;
        if (threadId <= 0 || tgChatId == 0 || text.isEmpty) continue;
        try {
          final tgMsgId = await svc.sendTextReturningId(tgChatId, text);
          if (tgMsgId != null &&
              tgMsgId > 0 &&
              fcMessageId > 0 &&
              _repo != null) {
            await _repo!.registerTelegramGroupOutboundMap(
              threadId: threadId,
              fcMessageId: fcMessageId,
              tgChatId: tgChatId,
              tgMessageId: tgMsgId,
            );
          }
        } catch (e) {
          debugPrint('[group-bridge] flush item failed: $e');
          if (attempts < 8) {
            remain.add({...item, 'attempts': attempts + 1});
          }
        }
      }
      await prefs.setString(_pendingKey, jsonEncode(remain));
    } finally {
      _flushing = false;
    }
  }
}
