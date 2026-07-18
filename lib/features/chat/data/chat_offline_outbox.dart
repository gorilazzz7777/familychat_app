import 'dart:typed_data';

import '../../../core/cache/familychat_local_cache.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_network_status.dart';
import 'chat_realtime_utils.dart';

/// Очередь исходящих сообщений и реакций для офлайн-режима.
class ChatOfflineOutbox {
  ChatOfflineOutbox._();

  static int _idCounter = 0;

  static String _nextId() {
    _idCounter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
  }

  static Future<void> enqueueMessage({
    required int threadId,
    required int tempMessageId,
    String? body,
    int? replyToMessageId,
    List<int> mentionedUserIds = const [],
    List<ChatOutboxAttachment> attachments = const [],
  }) async {
    final items = await FamilyChatLocalCache.readOutboxItems();
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
      'kind': 'message',
      'thread_id': threadId,
      'temp_message_id': tempMessageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      if (body != null && body.isNotEmpty) 'body': body,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (mentionedUserIds.isNotEmpty) 'mentioned_user_ids': mentionedUserIds,
      if (attachmentMeta.isNotEmpty) 'attachments': attachmentMeta,
    });
    await FamilyChatLocalCache.writeOutboxItems(items);
  }

  static Future<void> enqueueReaction({
    required int threadId,
    required int messageId,
    required String emoji,
  }) async {
    final items = await FamilyChatLocalCache.readOutboxItems();
    items.add({
      'id': _nextId(),
      'kind': 'reaction',
      'thread_id': threadId,
      'message_id': messageId,
      'emoji': emoji,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await FamilyChatLocalCache.writeOutboxItems(items);
  }

  static Future<int> pendingCount() async {
    final items = await FamilyChatLocalCache.readOutboxItems();
    return items.length;
  }

  static Future<List<ChatOutboxDelivery>> sync(FamilyChatRepository repo) async {
    final items = await FamilyChatLocalCache.readOutboxItems();
    if (items.isEmpty) return const [];

    final delivered = <ChatOutboxDelivery>[];
    final remaining = <Map<String, dynamic>>[];

    for (final item in items) {
      try {
        final kind = item['kind']?.toString();
        if (kind == 'message') {
          final result = await _deliverMessage(repo, item);
          if (result != null) delivered.add(result);
          continue;
        }
        if (kind == 'reaction') {
          final result = await _deliverReaction(repo, item);
          if (result != null) delivered.add(result);
          continue;
        }
        remaining.add(item);
      } catch (error) {
        remaining.add(item);
        if (ChatNetworkStatus.looksOffline(error)) break;
      }
    }

    await FamilyChatLocalCache.writeOutboxItems(remaining);
    return delivered;
  }

  static Future<ChatOutboxDelivery?> _deliverMessage(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    final tempMessageId = chatAsInt(item['temp_message_id']);
    if (threadId == null || tempMessageId == null) return null;

    final attachmentIds = <int>[];
    final rawAttachments = item['attachments'];
    if (rawAttachments is List) {
      for (final raw in rawAttachments) {
        if (raw is! Map) continue;
        final storageKey = raw['storage_key']?.toString();
        final filename = raw['filename']?.toString() ?? 'file';
        final contentType = raw['content_type']?.toString();
        if (storageKey == null || storageKey.isEmpty) continue;
        final bytes = await FamilyChatLocalCache.readOutboxBytes(storageKey);
        if (bytes == null || bytes.isEmpty) continue;
        final uploaded = await repo.uploadChatAttachmentBytes(
          threadId,
          bytes: bytes,
          filename: filename,
          contentType: contentType,
        );
        final id = chatAsInt(uploaded['id']);
        if (id != null) attachmentIds.add(id);
        await FamilyChatLocalCache.deleteOutboxBytes(storageKey);
      }
    }

    final body = item['body']?.toString();
    final replyTo = chatAsInt(item['reply_to_message_id']);
    final mentioned = chatAsIntList(item['mentioned_user_ids']);

    final msg = await repo.sendThreadMessage(
      threadId,
      body: body,
      attachmentIds: attachmentIds.isEmpty ? null : attachmentIds,
      replyToMessageId: replyTo,
      mentionedUserIds: mentioned.isEmpty ? null : mentioned,
    );

    final messages = await FamilyChatLocalCache.readThreadMessages(threadId) ?? [];
    final withoutTemp = messages
        .where((m) => chatAsInt(m['id']) != tempMessageId)
        .toList();
    withoutTemp.add(msg);
    await FamilyChatLocalCache.saveThreadMessages(
      threadId,
      withoutTemp,
    );

    return ChatOutboxDelivery(
      threadId: threadId,
      tempMessageId: tempMessageId,
      message: msg,
    );
  }

  static Future<ChatOutboxDelivery?> _deliverReaction(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    final messageId = chatAsInt(item['message_id']);
    final emoji = item['emoji']?.toString();
    if (threadId == null || messageId == null || emoji == null || emoji.isEmpty) {
      return null;
    }
    final reactions = await repo.toggleMessageReaction(threadId, messageId, emoji);
    return ChatOutboxDelivery(
      threadId: threadId,
      messageId: messageId,
      reactions: reactions
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }
}

class ChatOutboxAttachment {
  const ChatOutboxAttachment({
    required this.bytes,
    required this.filename,
    this.contentType,
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
}

class ChatOutboxDelivery {
  const ChatOutboxDelivery({
    required this.threadId,
    this.tempMessageId,
    this.message,
    this.messageId,
    this.reactions,
  });

  final int threadId;
  final int? tempMessageId;
  final Map<String, dynamic>? message;
  final int? messageId;
  final List<Map<String, dynamic>>? reactions;
}
