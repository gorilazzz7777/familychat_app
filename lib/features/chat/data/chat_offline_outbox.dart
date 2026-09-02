import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_media_upload_tracker.dart';
import 'chat_realtime_utils.dart';
import 'chat_send_trace.dart';
import 'chat_ws_mark_read.dart';
import 'chat_network_status.dart';

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

  /// Temp ids with an active outbox row (message not yet delivered).
  static Future<Set<int>> activeTempMessageIds({int? threadId}) async {
    final items = await _readItems();
    return {
      for (final item in items)
        if (item['kind']?.toString() == 'message')
          if (threadId == null || chatAsInt(item['thread_id']) == threadId)
            if (chatAsInt(item['temp_message_id']) != null)
              chatAsInt(item['temp_message_id'])!,
    };
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
    int? clientMsgId,
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
        'attempts': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        if (clientMsgId != null) 'client_msg_id': clientMsgId,
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
    await _serialized(() async {
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
    });
  }

  static final Map<int, Set<int>> _removalTombstones = {};

  /// Block sync/WS from re-upserting messages the user already deleted locally.
  static void markMessagesPendingRemoval(int threadId, Iterable<int> messageIds) {
    if (messageIds.isEmpty) return;
    _removalTombstones
        .putIfAbsent(threadId, () => <int>{})
        .addAll(messageIds.where((id) => id > 0));
  }

  static void clearMessagesPendingRemoval(
    int threadId,
    Iterable<int> messageIds,
  ) {
    final set = _removalTombstones[threadId];
    if (set == null || messageIds.isEmpty) return;
    set.removeAll(messageIds);
    if (set.isEmpty) _removalTombstones.remove(threadId);
  }

  static bool isMessagePendingRemoval(int threadId, int messageId) {
    return _removalTombstones[threadId]?.contains(messageId) ?? false;
  }

  /// In-memory tombstones + outbox delete/hide still waiting for the server.
  static Future<Set<int>> pendingRemovalMessageIds({int? threadId}) async {
    final ids = <int>{};
    if (threadId != null) {
      ids.addAll(_removalTombstones[threadId] ?? const {});
    } else {
      for (final set in _removalTombstones.values) {
        ids.addAll(set);
      }
    }
    final items = await _readItems();
    for (final item in items) {
      final kind = item['kind']?.toString();
      if (kind != 'delete_messages' && kind != 'hide_messages') continue;
      if (threadId != null && chatAsInt(item['thread_id']) != threadId) {
        continue;
      }
      ids.addAll(chatAsIntList(item['message_ids']));
    }
    return ids;
  }

  static Future<void> _enqueueRaw(Map<String, dynamic> item) async {
    await _serialized(() async {
      final items = await _readItems();
      items.add(item);
      await _writeItems(items);
    });
  }

  static Future<void> enqueueDeleteMessages({
    required int threadId,
    required List<int> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    markMessagesPendingRemoval(threadId, messageIds);
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'delete_messages',
      'thread_id': threadId,
      'message_ids': messageIds,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueueHideMessagesForMe({
    required int threadId,
    required List<int> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    markMessagesPendingRemoval(threadId, messageIds);
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'hide_messages',
      'thread_id': threadId,
      'message_ids': messageIds,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueuePin({
    required int threadId,
    required int messageId,
  }) async {
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'pin',
      'thread_id': threadId,
      'message_id': messageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueueUnpin({
    required int threadId,
    required int messageId,
  }) async {
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'unpin',
      'thread_id': threadId,
      'message_id': messageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueueEditMessage({
    required int threadId,
    required int messageId,
    required String body,
  }) async {
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'edit_message',
      'thread_id': threadId,
      'message_id': messageId,
      'body': body,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueueMute({
    required int threadId,
    required String muteKey,
  }) async {
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'mute',
      'thread_id': threadId,
      'mute': muteKey,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueueQuietHours({
    required int threadId,
    required String start,
    required String end,
    required int utcOffsetMinutes,
  }) async {
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'quiet_hours',
      'thread_id': threadId,
      'start': start,
      'end': end,
      'utc_offset_minutes': utcOffsetMinutes,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueueClearQuietHours({
    required int threadId,
  }) async {
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'clear_quiet_hours',
      'thread_id': threadId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> enqueueReaction({
    required int threadId,
    required int messageId,
    required String emoji,
  }) async {
    await _enqueueRaw({
      'id': _nextId(),
      'kind': 'reaction',
      'thread_id': threadId,
      'message_id': messageId,
      'emoji': emoji,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
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

  static const maxAttempts = 5;

  static Future<void> resumeMessage({
    required int threadId,
    required int tempMessageId,
  }) async {
    await _serialized(() async {
      final items = await _readItems();
      var changed = false;
      for (final item in items) {
        if (item['kind']?.toString() != 'message') continue;
        if (chatAsInt(item['thread_id']) != threadId) continue;
        if (chatAsInt(item['temp_message_id']) != tempMessageId) continue;
        item['attempts'] = 0;
        item.remove('next_retry_at');
        item.remove('paused');
        changed = true;
      }
      if (changed) await _writeItems(items);
    });
  }

  static Future<void> _patchItem(String itemId, Map<String, dynamic> patch) async {
    await _serialized(() async {
      final items = await _readItems();
      var changed = false;
      for (final item in items) {
        if (item['id']?.toString() != itemId) continue;
        item.addAll(patch);
        changed = true;
      }
      if (changed) await _writeItems(items);
    });
  }

  static DateTime _nextRetryAt(int attempts) {
    final shift = (attempts - 1).clamp(0, 4);
    final seconds = 1 << shift; // 1, 2, 4, 8, 16
    return DateTime.now().toUtc().add(Duration(seconds: seconds));
  }

  static Future<void> _markLocalMessageFailed(Map<String, dynamic> item) async {
    final threadId = chatAsInt(item['thread_id']);
    final tempId = chatAsInt(item['temp_message_id']);
    if (threadId == null || tempId == null) return;
    if (!ChatLocalStore.isSupported) return;
    await ChatLocalStore.instance.patchMessageFields(
      threadId,
      tempId,
      {'read_status': 'failed'},
    );
  }

  static Future<ChatOutboxSyncResult> sync(FamilyChatRepository repo) async {
    final delivered = <ChatOutboxDelivery>[];
    final skippedIds = <String>{};
    DateTime? nextRetryAt;

    while (true) {
      final items = await _readItems();
      // Prefer outgoing messages over mark_read/mute/etc so typing isn't
      // blocked behind lower-priority outbox work.
      final item = _pickNextOutboxItem(
        items,
        skippedIds: skippedIds,
        onMessageDeferred: (retryAt) {
          final current = nextRetryAt;
          if (current == null || retryAt.isBefore(current)) {
            nextRetryAt = retryAt;
          }
        },
      );
      if (item == null) break;

      final itemId = item['id']?.toString() ?? '';
      if (itemId.isEmpty) {
        debugPrint('[ChatOutbox] skip item without id kind=${item['kind']}');
        break;
      }
      try {
        final kind = item['kind']?.toString();
        ChatOutboxDelivery? result;
        var removeFromQueue = true;
        if (kind == 'message') {
          result = await _deliverMessage(repo, item);
          if (result == null) {
            removeFromQueue = false;
            if (itemId.isNotEmpty) skippedIds.add(itemId);
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
          await _removeItemById(itemId);
          continue;
        }
        if (result != null) delivered.add(result);
        if (removeFromQueue) {
          await _removeItemById(itemId);
        }
      } catch (error, st) {
        if (itemId.isNotEmpty) skippedIds.add(itemId);
        debugPrint('[ChatOutbox] fail id=$itemId error=$error\n$st');
        if (item['kind']?.toString() == 'message') {
          final tempId = chatAsInt(item['temp_message_id']);
          final threadId = chatAsInt(item['thread_id']);
          final cancelled = (error is DioException && CancelToken.isCancel(error)) ||
              (tempId != null &&
                  ChatMediaUploadTracker.shared?.isCancelled(tempId) == true);
          if (cancelled && threadId != null && tempId != null) {
            await cancelMessage(threadId: threadId, tempMessageId: tempId);
            if (ChatLocalStore.isSupported) {
              await ChatLocalStore.instance.deleteMessages(threadId, [tempId]);
            }
            await _removeItemById(itemId);
            ChatMediaUploadTracker.shared?.complete(tempId);
            continue;
          }
          final attempts = (chatAsInt(item['attempts']) ?? 0) + 1;
          final giveUp =
              attempts >= maxAttempts || !ChatNetworkStatus.isRetryable(error);
          if (giveUp) {
            await _patchItem(itemId, {
              'attempts': attempts,
              'paused': true,
            });
            await _markLocalMessageFailed(item);
            final threadId = chatAsInt(item['thread_id']);
            final tempId = chatAsInt(item['temp_message_id']);
            if (threadId != null) {
              delivered.add(
                ChatOutboxDelivery(
                  threadId: threadId,
                  tempMessageId: tempId,
                  failed: true,
                ),
              );
            }
            debugPrint(
              '[ChatOutbox] gave up temp=${item['temp_message_id']} after $attempts attempts',
            );
          } else {
            final retryAt = _nextRetryAt(attempts);
            await _patchItem(itemId, {
              'attempts': attempts,
              'next_retry_at': retryAt.toIso8601String(),
            });
            final current = nextRetryAt;
            if (current == null || retryAt.isBefore(current)) {
              nextRetryAt = retryAt;
            }
            debugPrint(
              '[ChatOutbox] retry $attempts/$maxAttempts at $retryAt temp=${item['temp_message_id']}',
            );
          }
        }
        if (ChatNetworkStatus.looksOffline(error)) break;
      }
    }

    return ChatOutboxSyncResult(
      deliveries: delivered,
      nextRetryAt: nextRetryAt,
    );
  }

  /// Ready messages first (FIFO among messages), then other kinds in queue order.
  static Map<String, dynamic>? _pickNextOutboxItem(
    List<Map<String, dynamic>> items, {
    required Set<String> skippedIds,
    required void Function(DateTime retryAt) onMessageDeferred,
  }) {
    Map<String, dynamic>? firstOther;
    for (final candidate in items) {
      final id = candidate['id']?.toString() ?? '';
      if (id.isEmpty || skippedIds.contains(id)) continue;
      if (candidate['kind']?.toString() == 'message') {
        final attempts = chatAsInt(candidate['attempts']) ?? 0;
        if (attempts >= maxAttempts || candidate['paused'] == true) {
          skippedIds.add(id);
          continue;
        }
        final retryAt = DateTime.tryParse(
          candidate['next_retry_at']?.toString() ?? '',
        );
        if (retryAt != null && retryAt.isAfter(DateTime.now().toUtc())) {
          skippedIds.add(id);
          onMessageDeferred(retryAt);
          continue;
        }
        return candidate;
      }
      firstOther ??= candidate;
    }
    return firstOther;
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

    final tracker = ChatMediaUploadTracker.shared;
    CancelToken? cancelToken;
    if (tracker != null) {
      tracker.resetCancellation(tempMessageId);
      cancelToken = tracker.begin(tempMessageId);
    }

    try {
    final sw = Stopwatch()..start();
    var uploadMs = 0;
    var httpMs = 0;
    var localMs = 0;
    final createdRaw = item['created_at']?.toString();
    final enqueuedAt =
        createdRaw == null || createdRaw.isEmpty ? null : DateTime.tryParse(createdRaw);
    final queueWaitMs = enqueuedAt == null
        ? null
        : DateTime.now().toUtc().difference(enqueuedAt.toUtc()).inMilliseconds;

    final attachmentIds = <int>[];
    final rawAttachments = item['attachments'];
    if (rawAttachments is List) {
      final uploadSw = Stopwatch()..start();
      var totalBytes = 0;
      final payloads = <({Uint8List bytes, String filename, String? contentType, String storageKey})>[];
      for (final raw in rawAttachments) {
        if (raw is! Map) continue;
        final storageKey = raw['storage_key']?.toString();
        final filename = raw['filename']?.toString() ?? 'file';
        final contentType = raw['content_type']?.toString();
        if (storageKey == null || storageKey.isEmpty) continue;
        final bytes = await _readBytes(storageKey);
        if (bytes == null || bytes.isEmpty) continue;
        totalBytes += bytes.length;
        payloads.add((
          bytes: bytes,
          filename: filename,
          contentType: contentType,
          storageKey: storageKey,
        ));
      }
      var sentSoFar = 0;
      for (final payload in payloads) {
        if (tracker?.isCancelled(tempMessageId) == true) {
          throw DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.cancel,
          );
        }
        final uploaded = await repo.uploadChatAttachmentBytes(
          threadId,
          bytes: payload.bytes,
          filename: payload.filename,
          contentType: payload.contentType,
          cancelToken: cancelToken,
          onSendProgress: (sent, total) {
            final current = sentSoFar + sent;
            final denom = totalBytes > 0 ? totalBytes : total;
            tracker?.update(
              tempMessageId,
              denom > 0 ? current / denom : 0,
            );
          },
        );
        sentSoFar += payload.bytes.length;
        tracker?.update(
          tempMessageId,
          totalBytes > 0 ? sentSoFar / totalBytes : 1,
        );
        final id = chatAsInt(uploaded['id']);
        if (id != null) attachmentIds.add(id);
        await _deleteBytes(payload.storageKey);
      }
      uploadMs = uploadSw.elapsedMilliseconds;
    }

    final body = item['body']?.toString();
    final replyTo = chatAsInt(item['reply_to_message_id']);
    final mentioned = chatAsIntList(item['mentioned_user_ids']);

    final httpSw = Stopwatch()..start();
    final msg = await repo.sendThreadMessage(
      threadId,
      body: body,
      attachmentIds: attachmentIds.isEmpty ? null : attachmentIds,
      replyToMessageId: replyTo,
      mentionedUserIds: mentioned.isEmpty ? null : mentioned,
      notifySilent: item['notify_silent'] == true,
      clientMsgId: chatAsInt(item['client_msg_id']) ?? tempMessageId,
      voiceDurationMs: chatAsInt(item['voice_duration_ms']),
      voiceTranscript: item['voice_transcript']?.toString(),
      videoNoteDurationMs: chatAsInt(item['video_note_duration_ms']),
    );
    httpMs = httpSw.elapsedMilliseconds;

    final serverId = chatAsInt(msg['id']);
    if (serverId == null || serverId <= 0) {
      throw StateError(
        'sendThreadMessage returned no id (temp=$tempMessageId)',
      );
    }

    final localSw = Stopwatch()..start();
    if (ChatLocalStore.isSupported) {
      // Upsert server row first, then drop temp — otherwise a watch between
      // delete and upsert briefly removes the bubble from the UI.
      Map<String, dynamic>? pendingRow;
      final localRows = await ChatLocalStore.instance.readMessages(threadId);
      for (final row in localRows) {
        if (chatAsInt(row['id']) == tempMessageId) {
          pendingRow = row;
          break;
        }
      }
      final serverMsg = chatEnsureMessageOwnership(
        {...msg, 'thread_id': msg['thread_id'] ?? threadId},
        previous: pendingRow,
      );
      // Outbox delivery is always our send — keep ownership even if API omits it.
      serverMsg['is_mine'] = true;
      ChatSendTrace.log(
        'outbox_sqlite_upsert_server',
        threadId: threadId,
        tempId: tempMessageId,
        serverId: serverId,
        source: 'outbox',
      );
      await ChatLocalStore.instance.upsertMessage(serverMsg);
      ChatSendTrace.log(
        'outbox_sqlite_delete_temp',
        threadId: threadId,
        tempId: tempMessageId,
        serverId: serverId,
        source: 'outbox',
        detail: 'after_upsert_server',
      );
      await ChatLocalStore.instance.deleteMessages(threadId, [tempMessageId]);
      localMs = localSw.elapsedMilliseconds;

      debugPrint(
        '[chat_send_timing] scope=client_outbox '
        'thread_id=$threadId temp=$tempMessageId message_id=$serverId '
        'attachments=${attachmentIds.length} '
        'total=${sw.elapsedMilliseconds}ms '
        'upload=${uploadMs}ms http=${httpMs}ms local=${localMs}ms '
        'queue_wait_ms=${queueWaitMs ?? "n/a"}',
      );

      debugPrint(
        '[ChatOutbox] sent thread=$threadId temp=$tempMessageId -> $serverId',
      );

      return ChatOutboxDelivery(
        threadId: threadId,
        tempMessageId: tempMessageId,
        message: serverMsg,
      );
    } else {
      final messages =
          await FamilyChatLocalCache.readThreadMessages(threadId) ?? [];
      Map<String, dynamic>? pendingRow;
      for (final row in messages) {
        if (chatAsInt(row['id']) == tempMessageId) {
          pendingRow = row;
          break;
        }
      }
      final serverMsg = chatEnsureMessageOwnership(
        {...msg, 'thread_id': msg['thread_id'] ?? threadId},
        previous: pendingRow,
      );
      serverMsg['is_mine'] = true;
      final withoutTemp = messages
          .where((m) => chatAsInt(m['id']) != tempMessageId)
          .toList();
      withoutTemp.add(serverMsg);
      await FamilyChatLocalCache.saveThreadMessages(threadId, withoutTemp);
      localMs = localSw.elapsedMilliseconds;

      debugPrint(
        '[chat_send_timing] scope=client_outbox '
        'thread_id=$threadId temp=$tempMessageId message_id=$serverId '
        'attachments=${attachmentIds.length} '
        'total=${sw.elapsedMilliseconds}ms '
        'upload=${uploadMs}ms http=${httpMs}ms local=${localMs}ms '
        'queue_wait_ms=${queueWaitMs ?? "n/a"}',
      );

      debugPrint(
        '[ChatOutbox] sent thread=$threadId temp=$tempMessageId -> $serverId',
      );

      return ChatOutboxDelivery(
        threadId: threadId,
        tempMessageId: tempMessageId,
        message: serverMsg,
      );
    }
    } finally {
      tracker?.complete(tempMessageId);
    }
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
    final wsOk = await ChatWsMarkRead.tryMarkRead(
      threadId: threadId,
      lastMessageId: lastId,
    );
    if (wsOk) return;
    try {
      await repo.markThreadRead(threadId, lastMessageId: lastId);
    } catch (e, st) {
      debugPrint('[ChatOfflineOutbox] mark_read HTTP fallback failed: $e\n$st');
      rethrow;
    }
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
    clearMessagesPendingRemoval(threadId, deleted);
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
    clearMessagesPendingRemoval(threadId, hidden);
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
    this.failed = false,
  });

  final int threadId;
  final int? tempMessageId;
  final Map<String, dynamic>? message;
  final int? messageId;
  final List<Map<String, dynamic>>? reactions;
  final List<int>? deletedMessageIds;
  final List<Map<String, dynamic>>? pinnedMessages;
  final bool failed;
}

class ChatOutboxSyncResult {
  const ChatOutboxSyncResult({
    required this.deliveries,
    this.nextRetryAt,
  });

  final List<ChatOutboxDelivery> deliveries;
  final DateTime? nextRetryAt;
}
