import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_network_status.dart';
import 'chat_offline_outbox.dart';
import 'familychat_realtime.dart';

class ScheduledSendDelivery {
  const ScheduledSendDelivery({
    required this.threadId,
    required this.scheduleId,
  });

  final int threadId;
  final String scheduleId;
}

/// Локальная очередь отложенных сообщений (работает вне экрана чата).
class ChatScheduledSendService extends ChangeNotifier {
  ChatScheduledSendService._();

  static final ChatScheduledSendService instance = ChatScheduledSendService._();

  static const _maxOneShotDelay = Duration(hours: 24);

  FamilyChatRepository? _repo;
  Timer? _pollTimer;
  final _oneShotTimers = <String, Timer>{};
  List<ScheduledSendDelivery> _recentDeliveries = const [];
  bool _dispatching = false;

  List<ScheduledSendDelivery> consumeDeliveries() {
    final items = _recentDeliveries;
    _recentDeliveries = const [];
    return items;
  }

  void start(FamilyChatRepository repo) {
    _repo = repo;
    _pollTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(dispatchDue());
    });
    unawaited(_rescheduleAll());
    unawaited(dispatchDue());
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final timer in _oneShotTimers.values) {
      timer.cancel();
    }
    _oneShotTimers.clear();
    _repo = null;
  }

  static int _idCounter = 0;

  static String _nextId() {
    _idCounter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
  }

  static Future<List<Map<String, dynamic>>> itemsForThread(int threadId) async {
    final items = await FamilyChatLocalCache.readScheduledItems();
    return items
        .where((item) => item['thread_id'] == threadId)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  static Future<void> enqueue({
    required int threadId,
    required DateTime sendAt,
    String? body,
    int? replyToMessageId,
    List<int> mentionedUserIds = const [],
    bool silent = false,
    List<ChatOutboxAttachment> attachments = const [],
  }) async {
    final items = await FamilyChatLocalCache.readScheduledItems();
    final attachmentMeta = <Map<String, dynamic>>[];
    for (var i = 0; i < attachments.length; i++) {
      final att = attachments[i];
      final storageKey = '${_nextId()}_$i';
      await FamilyChatLocalCache.saveOutboxBytes(storageKey, att.bytes);
      attachmentMeta.add({
        'storage_key': storageKey,
        'filename': att.filename,
        if (att.contentType != null) 'content_type': att.contentType,
      });
    }
    final item = <String, dynamic>{
      'id': _nextId(),
      'thread_id': threadId,
      'send_at': sendAt.toUtc().toIso8601String(),
      'silent': silent,
      if (body != null && body.isNotEmpty) 'body': body,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (mentionedUserIds.isNotEmpty) 'mentioned_user_ids': mentionedUserIds,
      if (attachmentMeta.isNotEmpty) 'attachments': attachmentMeta,
    };
    items.add(item);
    await FamilyChatLocalCache.writeScheduledItems(items);
    instance._scheduleOneShot(item);
    unawaited(instance.dispatchDue());
  }

  static Future<void> remove(String scheduleId) async {
    instance._cancelOneShot(scheduleId);
    final items = await FamilyChatLocalCache.readScheduledItems();
    final remaining = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item['id']?.toString() == scheduleId) {
        final attachments = item['attachments'];
        if (attachments is List) {
          for (final raw in attachments) {
            if (raw is Map) {
              final key = raw['storage_key']?.toString();
              if (key != null && key.isNotEmpty) {
                await FamilyChatLocalCache.deleteOutboxBytes(key);
              }
            }
          }
        }
        continue;
      }
      remaining.add(item);
    }
    await FamilyChatLocalCache.writeScheduledItems(remaining);
  }

  Future<void> _rescheduleAll() async {
    final items = await FamilyChatLocalCache.readScheduledItems();
    for (final item in items) {
      _scheduleOneShot(item);
    }
  }

  void _scheduleOneShot(Map<String, dynamic> item) {
    final scheduleId = item['id']?.toString();
    final sendAt = DateTime.tryParse(item['send_at']?.toString() ?? '');
    if (scheduleId == null || scheduleId.isEmpty || sendAt == null) return;

    _cancelOneShot(scheduleId);
    final delay = sendAt.toUtc().difference(DateTime.now().toUtc());
    if (delay > _maxOneShotDelay) return;

    _oneShotTimers[scheduleId] = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        _oneShotTimers.remove(scheduleId);
        unawaited(dispatchDue());
      },
    );
  }

  void _cancelOneShot(String scheduleId) {
    _oneShotTimers.remove(scheduleId)?.cancel();
  }

  Future<void> dispatchDue() async {
    if (_dispatching) return;
    final repo = _repo;
    if (repo == null) return;

    final online = await ChatNetworkStatus.isOnline(() async {
      await repo.status();
    });
    if (!online) return;

    _dispatching = true;
    try {
      final now = DateTime.now().toUtc();
      final items = await FamilyChatLocalCache.readScheduledItems();
      final delivered = <ScheduledSendDelivery>[];

      for (final item in items) {
        final sendAt = DateTime.tryParse(item['send_at']?.toString() ?? '');
        if (sendAt == null || sendAt.isAfter(now)) continue;

        final threadId = item['thread_id'];
        final scheduleId = item['id']?.toString();
        if (threadId is! int || scheduleId == null || scheduleId.isEmpty) {
          continue;
        }

        try {
          await sendScheduledItem(repo: repo, item: item);
          _cancelOneShot(scheduleId);
          delivered.add(
            ScheduledSendDelivery(threadId: threadId, scheduleId: scheduleId),
          );
          FamilyChatRealtime.instance.emitSyntheticEvent({
            'event': 'chat_refresh',
            'thread_id': threadId,
          });
        } catch (_) {
          // Оставляем в очереди — повторим при следующем тике.
        }
      }

      if (delivered.isNotEmpty) {
        _recentDeliveries = [..._recentDeliveries, ...delivered];
        notifyListeners();
      }
    } finally {
      _dispatching = false;
    }
  }

  static Future<void> sendScheduledItem({
    required FamilyChatRepository repo,
    required Map<String, dynamic> item,
  }) async {
    final threadId = item['thread_id'] as int;
    final ids = <int>[];
    final attachments = item['attachments'];
    if (attachments is List) {
      for (final raw in attachments) {
        if (raw is! Map) continue;
        final storageKey = raw['storage_key']?.toString();
        if (storageKey == null || storageKey.isEmpty) continue;
        final bytes = await FamilyChatLocalCache.readOutboxBytes(storageKey);
        if (bytes == null || bytes.isEmpty) continue;
        final uploaded = await repo.uploadChatAttachmentBytes(
          threadId,
          bytes: bytes,
          filename: raw['filename']?.toString() ?? 'file',
          contentType: raw['content_type']?.toString(),
        );
        final id = int.tryParse('${uploaded['id']}');
        if (id != null) ids.add(id);
      }
    }
    final mentioned = item['mentioned_user_ids'];
    await repo.sendThreadMessage(
      threadId,
      body: item['body']?.toString(),
      attachmentIds: ids.isEmpty ? null : ids,
      replyToMessageId: item['reply_to_message_id'] as int?,
      mentionedUserIds: mentioned is List
          ? mentioned.map((e) => int.tryParse('$e') ?? 0).where((i) => i > 0).toList()
          : null,
      notifySilent: item['silent'] == true,
    );
    await remove(item['id']?.toString() ?? '');
  }
}
