import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_network_status.dart';
import 'chat_realtime_utils.dart';

/// Очередь исходящих сообщений и реакций для офлайн-режима (Drift).
class ChatOfflineOutbox {
  ChatOfflineOutbox._();

  static int _idCounter = 0;
  static Future<void> _mutationChain = Future<void>.value();

  static String _nextId() {
    _idCounter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
  }

  /// Serialize read-modify-write so enqueue/cancel/sync cannot clobber each other.
  static Future<T> _serialized<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _mutationChain = _mutationChain.then((_) async {
      try {
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  static Future<List<Map<String, dynamic>>> _readItems() async {
    if (ChatLocalStore.isSupported) {
      return ChatLocalStore.instance.readOutboxItems();
    }
    return FamilyChatLocalCache.readOutboxItems();
  }

  static Future<void> _writeItems(List<Map<String, dynamic>> items) async {
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.writeOutboxItems(items);
      return;
    }
    await FamilyChatLocalCache.writeOutboxItems(items);
  }

  static Future<void> _saveBytes(String storageKey, Uint8List bytes) async {
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.saveOutboxBlob(storageKey, bytes);
      return;
    }
    await FamilyChatLocalCache.saveOutboxBytes(storageKey, bytes);
  }

  static Future<Uint8List?> _readBytes(String storageKey) async {
    if (ChatLocalStore.isSupported) {
      return ChatLocalStore.instance.readOutboxBlob(storageKey);
    }
    return FamilyChatLocalCache.readOutboxBytes(storageKey);
  }

  static Future<void> _deleteBytes(String storageKey) async {
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.deleteOutboxBlob(storageKey);
      return;
    }
    await FamilyChatLocalCache.deleteOutboxBytes(storageKey);
  }

  static Future<void> enqueueMessage({
    required int threadId,
    required int tempMessageId,
    String? body,
    int? replyToMessageId,
    List<int> mentionedUserIds = const [],
    List<ChatOutboxAttachment> attachments = const [],
    bool notifySilent = false,
    int? voiceDurationMs,
    String? voiceTranscript,
    int? videoNoteDurationMs,
  }) async {
    final attachmentMeta = <Map<String, dynamic>>[];
    for (var i = 0; i < attachments.length; i++) {
      final att = attachments[i];
      final storageKey = '${_nextId()}_$i';
      await _saveBytes(storageKey, att.bytes);
      attachmentMeta.add({
        'storage_key': storageKey,
        'filename': att.filename,
        if (att.contentType != null) 'content_type': att.contentType,
      });
    }
    await _serialized(() async {
      final items = await _readItems();
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
        if (notifySilent) 'notify_silent': true,
        if (voiceDurationMs != null) 'voice_duration_ms': voiceDurationMs,
        if (voiceTranscript != null && voiceTranscript.isNotEmpty)
          'voice_transcript': voiceTranscript,
        if (videoNoteDurationMs != null)
          'video_note_duration_ms': videoNoteDurationMs,
      });
      await _writeItems(items);
    });
  }

  static Future<void> enqueueMarkRead({
    required int threadId,
    required int lastMessageId,
  }) async {
    final items = await _readItems();
    items.removeWhere(
      (item) =>
          item['kind']?.toString() == 'mark_read' &&
          chatAsInt(item['thread_id']) == threadId,
    );
    items.add({
      'id': _nextId(),
      'kind': 'mark_read',
      'thread_id': threadId,
      'last_message_id': lastMessageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueDeleteMessages({
    required int threadId,
    required List<int> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'delete_messages',
      'thread_id': threadId,
      'message_ids': messageIds,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueHideMessagesForMe({
    required int threadId,
    required List<int> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'hide_messages',
      'thread_id': threadId,
      'message_ids': messageIds,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueuePin({
    required int threadId,
    required int messageId,
  }) async {
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'pin',
      'thread_id': threadId,
      'message_id': messageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueUnpin({
    required int threadId,
    required int messageId,
  }) async {
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'unpin',
      'thread_id': threadId,
      'message_id': messageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueEditMessage({
    required int threadId,
    required int messageId,
    required String body,
  }) async {
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'edit_message',
      'thread_id': threadId,
      'message_id': messageId,
      'body': body,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueMute({
    required int threadId,
    required String muteKey,
  }) async {
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'mute',
      'thread_id': threadId,
      'mute': muteKey,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueQuietHours({
    required int threadId,
    required String start,
    required String end,
    required int utcOffsetMinutes,
  }) async {
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'quiet_hours',
      'thread_id': threadId,
      'start': start,
      'end': end,
      'utc_offset_minutes': utcOffsetMinutes,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueClearQuietHours({
    required int threadId,
  }) async {
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'clear_quiet_hours',
      'thread_id': threadId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  static Future<void> enqueueReaction({
    required int threadId,
    required int messageId,
    required String emoji,
  }) async {
    final items = await _readItems();
    items.add({
      'id': _nextId(),
      'kind': 'reaction',
      'thread_id': threadId,
      'message_id': messageId,
      'emoji': emoji,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeItems(items);
  }

  /// Remove a queued outgoing message (user cancelled a stuck/pending bubble).
  static Future<void> cancelMessage({
    required int threadId,
    required int tempMessageId,
  }) async {
    await _serialized(() async {
      final items = await _readItems();
      final remaining = <Map<String, dynamic>>[];
      for (final item in items) {
        if (item['kind']?.toString() != 'message') {
          remaining.add(item);
          continue;
        }
        if (chatAsInt(item['thread_id']) == threadId &&
            chatAsInt(item['temp_message_id']) == tempMessageId) {
          final rawAttachments = item['attachments'];
          if (rawAttachments is List) {
            for (final raw in rawAttachments) {
              if (raw is! Map) continue;
              final storageKey = raw['storage_key']?.toString();
              if (storageKey != null && storageKey.isNotEmpty) {
                await _deleteBytes(storageKey);
              }
            }
          }
          continue;
        }
        remaining.add(item);
      }
      await _writeItems(remaining);
    });
  }

  static Future<int> pendingCount() async {
    final items = await _readItems();
    return items.length;
  }

  static Future<List<ChatOutboxDelivery>> sync(FamilyChatRepository repo) async {
    final delivered = <ChatOutboxDelivery>[];
    final failedIds = <String>{};

    while (true) {
      final items = await _readItems();
      Map<String, dynamic>? item;
      for (final candidate in items) {
        final id = candidate['id']?.toString() ?? '';
        if (id.isEmpty || failedIds.contains(id)) continue;
        item = candidate;
        break;
      }
      if (item == null) break;

      final itemId = item['id']?.toString() ?? '';
      try {
        final kind = item['kind']?.toString();
        ChatOutboxDelivery? result;
        var removeFromQueue = true;
        if (kind == 'message') {
          result = await _deliverMessage(repo, item);
          if (result == null) {
            // Malformed — keep for visibility, skip rest of this pass.
            removeFromQueue = false;
            if (itemId.isNotEmpty) failedIds.add(itemId);
            debugPrint('[ChatOutbox] skip message without delivery id=$itemId');
          }
        } else if (kind == 'reaction') {
          result = await _deliverReaction(repo, item);
          if (result == null) removeFromQueue = false;
        } else if (kind == 'mark_read') {
          await _deliverMarkRead(repo, item);
        } else if (kind == 'delete_messages') {
          result = await _deliverDeleteMessages(repo, item);
          if (result == null) removeFromQueue = false;
        } else if (kind == 'hide_messages') {
          result = await _deliverHideMessages(repo, item);
          if (result == null) removeFromQueue = false;
        } else if (kind == 'pin') {
          result = await _deliverPin(repo, item, pin: true);
          if (result == null) removeFromQueue = false;
        } else if (kind == 'unpin') {
          result = await _deliverPin(repo, item, pin: false);
          if (result == null) removeFromQueue = false;
        } else if (kind == 'edit_message') {
          result = await _deliverEditMessage(repo, item);
          if (result == null) removeFromQueue = false;
        } else if (kind == 'mute') {
          await _deliverMute(repo, item);
        } else if (kind == 'quiet_hours') {
          await _deliverQuietHours(repo, item);
        } else if (kind == 'clear_quiet_hours') {
          await _deliverClearQuietHours(repo, item);
        } else {
          // Unknown kind — drop so it cannot block the queue forever.
          await _removeItemById(itemId);
          continue;
        }
        if (result != null) delivered.add(result);
        if (removeFromQueue) {
          await _removeItemById(itemId);
        }
      } catch (error, st) {
        if (itemId.isNotEmpty) failedIds.add(itemId);
        debugPrint('[ChatOutbox] fail id=$itemId error=$error\n$st');
        if (ChatNetworkStatus.looksOffline(error)) break;
      }
    }

    return delivered;
  }

  static Future<void> _removeItemById(String itemId) async {
    if (itemId.isEmpty) return;
    await _serialized(() async {
      final items = await _readItems();
      final remaining = items
          .where((item) => item['id']?.toString() != itemId)
          .toList(growable: false);
      if (remaining.length == items.length) return;
      await _writeItems(remaining);
    });
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
        final bytes = await _readBytes(storageKey);
        if (bytes == null || bytes.isEmpty) continue;
        final uploaded = await repo.uploadChatAttachmentBytes(
          threadId,
          bytes: bytes,
          filename: filename,
          contentType: contentType,
        );
        final id = chatAsInt(uploaded['id']);
        if (id != null) attachmentIds.add(id);
        await _deleteBytes(storageKey);
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
      notifySilent: item['notify_silent'] == true,
      voiceDurationMs: chatAsInt(item['voice_duration_ms']),
      voiceTranscript: item['voice_transcript']?.toString(),
      videoNoteDurationMs: chatAsInt(item['video_note_duration_ms']),
    );

    final serverId = chatAsInt(msg['id']);
    if (serverId == null || serverId <= 0) {
      throw StateError(
        'sendThreadMessage returned no id (temp=$tempMessageId)',
      );
    }

    if (ChatLocalStore.isSupported) {
      // Upsert server row first, then drop temp — otherwise a watch between
      // delete and upsert briefly removes the bubble from the UI.
      final serverMsg = Map<String, dynamic>.from(msg);
      serverMsg['thread_id'] ??= threadId;
      await ChatLocalStore.instance.upsertMessage(serverMsg);
      await ChatLocalStore.instance.deleteMessages(threadId, [tempMessageId]);
    } else {
      final messages =
          await FamilyChatLocalCache.readThreadMessages(threadId) ?? [];
      final withoutTemp = messages
          .where((m) => chatAsInt(m['id']) != tempMessageId)
          .toList();
      withoutTemp.add(msg);
      await FamilyChatLocalCache.saveThreadMessages(threadId, withoutTemp);
    }

    debugPrint(
      '[ChatOutbox] sent thread=$threadId temp=$tempMessageId -> $serverId',
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

  static Future<void> _deliverMarkRead(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    final lastId = chatAsInt(item['last_message_id']);
    if (threadId == null || lastId == null) return;
    await repo.markThreadRead(threadId, lastMessageId: lastId);
  }

  static Future<ChatOutboxDelivery?> _deliverDeleteMessages(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    final ids = chatAsIntList(item['message_ids']);
    if (threadId == null || ids.isEmpty) return null;
    final deleted = await repo.deleteMessages(threadId, ids);
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.deleteMessages(threadId, deleted);
    }
    return ChatOutboxDelivery(
      threadId: threadId,
      deletedMessageIds: deleted,
    );
  }

  static Future<ChatOutboxDelivery?> _deliverHideMessages(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    final ids = chatAsIntList(item['message_ids']);
    if (threadId == null || ids.isEmpty) return null;
    final hidden = await repo.hideMessagesForMe(threadId, ids);
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.deleteMessages(threadId, hidden);
    }
    return ChatOutboxDelivery(
      threadId: threadId,
      deletedMessageIds: hidden,
    );
  }

  static Future<ChatOutboxDelivery?> _deliverPin(
    FamilyChatRepository repo,
    Map<String, dynamic> item, {
    required bool pin,
  }) async {
    final threadId = chatAsInt(item['thread_id']);
    final messageId = chatAsInt(item['message_id']);
    if (threadId == null || messageId == null) return null;
    final pins = pin
        ? await repo.pinMessage(threadId, messageId)
        : await repo.unpinMessage(threadId, messageId);
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.metaSet(
        'pins_v1_$threadId',
        jsonEncode(pins),
      );
    }
    return ChatOutboxDelivery(
      threadId: threadId,
      pinnedMessages: pins,
    );
  }

  static Future<ChatOutboxDelivery?> _deliverEditMessage(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    final messageId = chatAsInt(item['message_id']);
    final body = item['body']?.toString() ?? '';
    if (threadId == null || messageId == null || body.isEmpty) return null;
    final updated = await repo.updateThreadMessage(
      threadId,
      messageId,
      body: body,
    );
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.upsertMessage({
        ...updated,
        'thread_id': threadId,
      });
    }
    return ChatOutboxDelivery(
      threadId: threadId,
      messageId: messageId,
      message: updated,
    );
  }

  static Future<void> _deliverMute(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    final mute = item['mute']?.toString() ?? 'off';
    if (threadId == null) return;
    await repo.setThreadMute(threadId, mute);
  }

  static Future<void> _deliverQuietHours(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    if (threadId == null) return;
    await repo.setThreadQuietHours(
      threadId,
      start: item['start']?.toString() ?? '22:00',
      end: item['end']?.toString() ?? '08:00',
      utcOffsetMinutes: chatAsInt(item['utc_offset_minutes']) ?? 180,
    );
  }

  static Future<void> _deliverClearQuietHours(
    FamilyChatRepository repo,
    Map<String, dynamic> item,
  ) async {
    final threadId = chatAsInt(item['thread_id']);
    if (threadId == null) return;
    await repo.clearThreadQuietHours(threadId);
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
    this.deletedMessageIds,
    this.pinnedMessages,
  });

  final int threadId;
  final int? tempMessageId;
  final Map<String, dynamic>? message;
  final int? messageId;
  final List<Map<String, dynamic>>? reactions;
  final List<int>? deletedMessageIds;
  final List<Map<String, dynamic>>? pinnedMessages;
}
