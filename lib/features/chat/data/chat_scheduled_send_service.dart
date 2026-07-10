import 'dart:async';
import 'dart:typed_data';

import '../../../core/cache/familychat_local_cache.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_offline_outbox.dart';

typedef ScheduledSendHandler = Future<void> Function(
  int threadId,
  String scheduleId,
);

/// Локальная очередь отложенных сообщений.
class ChatScheduledSendService {
  ChatScheduledSendService._();

  static final ChatScheduledSendService instance = ChatScheduledSendService._();

  Timer? _timer;
  ScheduledSendHandler? _handler;

  void bind(ScheduledSendHandler handler) {
    _handler = handler;
    _timer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(dispatchDue());
    });
  }

  void unbind(ScheduledSendHandler handler) {
    if (_handler == handler) {
      _handler = null;
      _timer?.cancel();
      _timer = null;
    }
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
    items.add({
      'id': _nextId(),
      'thread_id': threadId,
      'send_at': sendAt.toUtc().toIso8601String(),
      'silent': silent,
      if (body != null && body.isNotEmpty) 'body': body,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (mentionedUserIds.isNotEmpty) 'mentioned_user_ids': mentionedUserIds,
      if (attachmentMeta.isNotEmpty) 'attachments': attachmentMeta,
    });
    await FamilyChatLocalCache.writeScheduledItems(items);
  }

  static Future<void> remove(String scheduleId) async {
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

  Future<void> dispatchDue() async {
    final handler = _handler;
    if (handler == null) return;
    final now = DateTime.now().toUtc();
    final items = await FamilyChatLocalCache.readScheduledItems();
    for (final item in items) {
      final sendAt = DateTime.tryParse(item['send_at']?.toString() ?? '');
      if (sendAt == null || sendAt.isAfter(now)) continue;
      final threadId = item['thread_id'];
      final scheduleId = item['id']?.toString();
      if (threadId is! int || scheduleId == null || scheduleId.isEmpty) continue;
      await handler(threadId, scheduleId);
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
