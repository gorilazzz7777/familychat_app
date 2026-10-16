import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/local_db/chat_local_store.dart';
import 'telegram_tdlib_service.dart';

/// Durable TG transcript window so openChat paints >1 message after process death.
///
/// TDLib `getChatHistory(only_local)` after cold start often has only
/// `chat.last_message` until remote pages arrive — hub tip + empty body.
abstract final class TdlibTranscriptCache {
  static const maxMessagesPerChat = 50;
  static const maxChats = 40;
  static const _indexKey = 'tg_transcript_index_v1';
  static const _chatKeyPrefix = 'tg_transcript_v1_';

  static String _chatKey(int chatId) => '$_chatKeyPrefix$chatId';

  static Future<List<TdlibMessage>> read(int chatId) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return const [];
    try {
      await ChatLocalStore.instance.ensureOpen();
      final raw = await ChatLocalStore.instance.metaGet(_chatKey(chatId));
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <TdlibMessage>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final m = messageFromCacheJson(Map<String, dynamic>.from(e));
        if (m != null) out.add(m);
      }
      out.sort((a, b) => a.id.compareTo(b.id));
      return out;
    } catch (e) {
      debugPrint('[tg-transcript-cache] read $chatId failed: $e');
      return const [];
    }
  }

  static Future<void> write(int chatId, List<TdlibMessage> messages) async {
    if (kIsWeb || !ChatLocalStore.isSupported) return;
    if (messages.isEmpty) return;
    try {
      await ChatLocalStore.instance.ensureOpen();
      final tail = messages.length <= maxMessagesPerChat
          ? messages
          : messages.sublist(messages.length - maxMessagesPerChat);
      final encoded = jsonEncode([
        for (final m in tail) messageToCacheJson(m),
      ]);
      await ChatLocalStore.instance.metaSet(_chatKey(chatId), encoded);
      await _touchIndex(chatId);
    } catch (e) {
      debugPrint('[tg-transcript-cache] write $chatId failed: $e');
    }
  }

  static Future<void> _touchIndex(int chatId) async {
    final raw = await ChatLocalStore.instance.metaGet(_indexKey);
    final ids = <int>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            final id = e is int ? e : int.tryParse('$e');
            if (id != null && id != chatId) ids.add(id);
          }
        }
      } catch (_) {}
    }
    ids.insert(0, chatId);
    while (ids.length > maxChats) {
      final evict = ids.removeLast();
      try {
        await ChatLocalStore.instance.metaSet(_chatKey(evict), '[]');
      } catch (_) {}
    }
    await ChatLocalStore.instance.metaSet(_indexKey, jsonEncode(ids));
  }

  static Map<String, dynamic> messageToCacheJson(TdlibMessage m) {
    return {
      'id': m.id,
      'chat_id': m.chatId,
      'sender_user_id': m.senderUserId,
      'is_outgoing': m.isOutgoing,
      'date': m.date,
      'text': m.text,
      if (m.textEntities.isNotEmpty) 'text_entities': m.textEntities,
      if (m.isService) 'is_service': true,
      if (m.mediaAlbumId != null) 'media_album_id': m.mediaAlbumId,
      if (m.photoLocalPath != null) 'photo_local_path': m.photoLocalPath,
      if (m.photoRemoteId != null) 'photo_remote_id': m.photoRemoteId,
      if (m.photoSizeType != null) 'photo_size_type': m.photoSizeType,
      if (m.photoWidth != null) 'photo_width': m.photoWidth,
      if (m.photoHeight != null) 'photo_height': m.photoHeight,
      if (m.photoFallbackFileIds.isNotEmpty)
        'photo_fallback_file_ids': m.photoFallbackFileIds,
      if (m.photoThumbBytes != null &&
          m.photoThumbBytes!.isNotEmpty &&
          m.photoThumbBytes!.length <= 8192)
        'photo_thumb_bytes': m.photoThumbBytes,
      if (m.voiceFileId != null) 'voice_file_id': m.voiceFileId,
      if (m.voiceLocalPath != null) 'voice_local_path': m.voiceLocalPath,
      if (m.voiceDurationMs != null) 'voice_duration_ms': m.voiceDurationMs,
      if (m.videoNoteFileId != null) 'video_note_file_id': m.videoNoteFileId,
      if (m.videoNoteLocalPath != null)
        'video_note_local_path': m.videoNoteLocalPath,
      if (m.videoNoteDurationMs != null)
        'video_note_duration_ms': m.videoNoteDurationMs,
      if (m.videoNoteThumbFileId != null)
        'video_note_thumb_file_id': m.videoNoteThumbFileId,
      if (m.videoNoteThumbLocalPath != null)
        'video_note_thumb_local_path': m.videoNoteThumbLocalPath,
      if (m.videoFileId != null) 'video_file_id': m.videoFileId,
      if (m.videoLocalPath != null) 'video_local_path': m.videoLocalPath,
      if (m.videoDurationMs != null) 'video_duration_ms': m.videoDurationMs,
      if (m.videoWidth != null) 'video_width': m.videoWidth,
      if (m.videoHeight != null) 'video_height': m.videoHeight,
      if (m.videoSizeBytes != null) 'video_size_bytes': m.videoSizeBytes,
      if (m.videoThumbFileId != null) 'video_thumb_file_id': m.videoThumbFileId,
      if (m.videoThumbLocalPath != null)
        'video_thumb_local_path': m.videoThumbLocalPath,
      if (m.isAnimation) 'is_animation': true,
      if (m.isSticker) 'is_sticker': true,
      if (m.stickerEmoji != null) 'sticker_emoji': m.stickerEmoji,
      if (m.documentFileId != null) 'document_file_id': m.documentFileId,
      if (m.documentLocalPath != null)
        'document_local_path': m.documentLocalPath,
      if (m.documentFileName != null) 'document_file_name': m.documentFileName,
      if (m.documentMimeType != null) 'document_mime_type': m.documentMimeType,
      if (m.documentSizeBytes != null)
        'document_size_bytes': m.documentSizeBytes,
      if (m.documentThumbFileId != null)
        'document_thumb_file_id': m.documentThumbFileId,
      if (m.documentThumbLocalPath != null)
        'document_thumb_local_path': m.documentThumbLocalPath,
      if (m.reactions.isNotEmpty)
        'reactions': [
          for (final r in m.reactions)
            {'emoji': r.emoji, 'count': r.count, 'chosen': r.chosen},
        ],
      if (m.replyToMessageId != null) 'reply_to_message_id': m.replyToMessageId,
      if (m.replyPreviewText.isNotEmpty) 'reply_preview_text': m.replyPreviewText,
      if (m.canBeEdited) 'can_be_edited': true,
      if (m.canBeDeletedForAllUsers) 'can_be_deleted_for_all_users': true,
      if (m.canBeDeletedOnlyForSelf) 'can_be_deleted_only_for_self': true,
      if (m.isPinned) 'is_pinned': true,
      if (m.forwardOriginName != null) 'forward_origin_name': m.forwardOriginName,
      if (m.forwardOriginChatTitle != null)
        'forward_origin_chat_title': m.forwardOriginChatTitle,
      if (m.forwardFromChatId != null) 'forward_from_chat_id': m.forwardFromChatId,
      if (m.forwardFromMessageId != null)
        'forward_from_message_id': m.forwardFromMessageId,
      if (m.sendingState != null) 'sending_state': m.sendingState,
    };
  }

  static TdlibMessage? messageFromCacheJson(Map<String, dynamic> j) {
    final id = (j['id'] as num?)?.toInt() ?? 0;
    final chatId = (j['chat_id'] as num?)?.toInt() ?? 0;
    if (id == 0 || chatId == 0) return null;
    final entitiesRaw = j['text_entities'];
    final entities = <Map<String, dynamic>>[];
    if (entitiesRaw is List) {
      for (final e in entitiesRaw) {
        if (e is Map) entities.add(Map<String, dynamic>.from(e));
      }
    }
    final reactions = <TdlibReaction>[];
    final reactionsRaw = j['reactions'];
    if (reactionsRaw is List) {
      for (final e in reactionsRaw) {
        if (e is! Map) continue;
        final emoji = e['emoji']?.toString() ?? '';
        if (emoji.isEmpty) continue;
        reactions.add(
          TdlibReaction(
            emoji: emoji,
            count: (e['count'] as num?)?.toInt() ?? 1,
            chosen: e['chosen'] == true,
          ),
        );
      }
    }
    List<int>? thumbBytes;
    final rawThumb = j['photo_thumb_bytes'];
    if (rawThumb is List) {
      thumbBytes = [
        for (final b in rawThumb)
          if (b is num) b.toInt(),
      ];
      if (thumbBytes.isEmpty) thumbBytes = null;
    }
    final fallbackRaw = j['photo_fallback_file_ids'];
    final fallback = <int>[];
    if (fallbackRaw is List) {
      for (final e in fallbackRaw) {
        final v = e is num ? e.toInt() : int.tryParse('$e');
        if (v != null && v > 0) fallback.add(v);
      }
    }
    return TdlibMessage(
      id: id,
      chatId: chatId,
      senderUserId: (j['sender_user_id'] as num?)?.toInt() ?? 0,
      isOutgoing: j['is_outgoing'] == true,
      date: (j['date'] as num?)?.toInt() ?? 0,
      text: j['text']?.toString() ?? '',
      textEntities: entities,
      isService: j['is_service'] == true,
      mediaAlbumId: (j['media_album_id'] as num?)?.toInt(),
      photoLocalPath: j['photo_local_path']?.toString(),
      photoRemoteId: (j['photo_remote_id'] as num?)?.toInt(),
      photoSizeType: j['photo_size_type']?.toString(),
      photoWidth: (j['photo_width'] as num?)?.toInt(),
      photoHeight: (j['photo_height'] as num?)?.toInt(),
      photoFallbackFileIds: fallback,
      photoThumbBytes: thumbBytes,
      voiceFileId: (j['voice_file_id'] as num?)?.toInt(),
      voiceLocalPath: j['voice_local_path']?.toString(),
      voiceDurationMs: (j['voice_duration_ms'] as num?)?.toInt(),
      videoNoteFileId: (j['video_note_file_id'] as num?)?.toInt(),
      videoNoteLocalPath: j['video_note_local_path']?.toString(),
      videoNoteDurationMs: (j['video_note_duration_ms'] as num?)?.toInt(),
      videoNoteThumbFileId: (j['video_note_thumb_file_id'] as num?)?.toInt(),
      videoNoteThumbLocalPath: j['video_note_thumb_local_path']?.toString(),
      videoFileId: (j['video_file_id'] as num?)?.toInt(),
      videoLocalPath: j['video_local_path']?.toString(),
      videoDurationMs: (j['video_duration_ms'] as num?)?.toInt(),
      videoWidth: (j['video_width'] as num?)?.toInt(),
      videoHeight: (j['video_height'] as num?)?.toInt(),
      videoSizeBytes: (j['video_size_bytes'] as num?)?.toInt(),
      videoThumbFileId: (j['video_thumb_file_id'] as num?)?.toInt(),
      videoThumbLocalPath: j['video_thumb_local_path']?.toString(),
      isAnimation: j['is_animation'] == true,
      isSticker: j['is_sticker'] == true,
      stickerEmoji: j['sticker_emoji']?.toString(),
      documentFileId: (j['document_file_id'] as num?)?.toInt(),
      documentLocalPath: j['document_local_path']?.toString(),
      documentFileName: j['document_file_name']?.toString(),
      documentMimeType: j['document_mime_type']?.toString(),
      documentSizeBytes: (j['document_size_bytes'] as num?)?.toInt(),
      documentThumbFileId: (j['document_thumb_file_id'] as num?)?.toInt(),
      documentThumbLocalPath: j['document_thumb_local_path']?.toString(),
      reactions: reactions,
      replyToMessageId: (j['reply_to_message_id'] as num?)?.toInt(),
      replyPreviewText: j['reply_preview_text']?.toString() ?? '',
      canBeEdited: j['can_be_edited'] == true,
      canBeDeletedForAllUsers: j['can_be_deleted_for_all_users'] == true,
      canBeDeletedOnlyForSelf: j['can_be_deleted_only_for_self'] == true,
      isPinned: j['is_pinned'] == true,
      forwardOriginName: j['forward_origin_name']?.toString(),
      forwardOriginChatTitle: j['forward_origin_chat_title']?.toString(),
      forwardFromChatId: (j['forward_from_chat_id'] as num?)?.toInt(),
      forwardFromMessageId: (j['forward_from_message_id'] as num?)?.toInt(),
      sendingState: j['sending_state']?.toString(),
    );
  }
}
