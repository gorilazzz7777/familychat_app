import 'dart:typed_data';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/image_upload_pipeline.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/media/video_upload_pipeline.dart';
import '../../familychat/data/familychat_repository.dart';
import '../data/chat_realtime_utils.dart';
import '../data/chat_sync_service.dart';
import '../data/share_attachment_loader.dart';

/// Оптимистичная отправка share → чат: сразу локальный bubble, upload в фоне.
class ShareChatSendCoordinator {
  ShareChatSendCoordinator._();

  static int _tempSeq = 0;

  static int nextTempId() {
    _tempSeq += 1;
    return -DateTime.now().microsecondsSinceEpoch - _tempSeq;
  }

  static List<Map<String, dynamic>> buildPendingAttachments(
    List<ShareAttachmentData> attachments,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final att in attachments) {
      final kind = att.isVideo
          ? 'video'
          : (att.isImage ? 'image' : 'file');
      final path = att.localPath?.trim() ?? '';
      final preview = safeUiPreviewBytes(
        bytes: att.bytes.isEmpty ? null : Uint8List.fromList(att.bytes),
        kind: kind,
      );
      out.add({
        'kind': kind,
        'filename': att.filename,
        if (att.contentType != null) 'content_type': att.contentType,
        if (path.isNotEmpty) 'local_device_path': path,
        if (preview != null) 'local_bytes': preview,
        '_pending': true,
      });
    }
    return out;
  }

  static Map<String, dynamic> buildPendingMessage({
    required int threadId,
    required int tempId,
    required int? senderUserId,
    required String caption,
    required List<Map<String, dynamic>> attachments,
  }) {
    return {
      'id': tempId,
      '_pending': true,
      'thread_id': threadId,
      'body': caption,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'sender_user_id': senderUserId,
      'sender_name': '',
      'sender_avatar_url': '',
      'attachments': attachments,
      'read_status': 'sending',
    };
  }

  static Future<void> seedPendingMessage(Map<String, dynamic> message) async {
    final threadId = chatAsInt(message['thread_id']);
    if (threadId == null) return;
    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.upsertMessage(message);
      return;
    }
    final existing =
        await FamilyChatLocalCache.readThreadMessages(threadId) ?? [];
    final next = chatUpsertMessage(existing, message);
    await FamilyChatLocalCache.saveThreadMessages(threadId, next);
  }

  static Future<void> replacePendingMessage({
    required int threadId,
    required int tempId,
    required Map<String, dynamic> serverMessage,
    List<Map<String, dynamic>>? pendingAttachments,
  }) async {
    final merged = Map<String, dynamic>.from(serverMessage);
    merged['thread_id'] ??= threadId;
    if (pendingAttachments != null && pendingAttachments.isNotEmpty) {
      final serverAtts = chatAttachmentsOf(merged);
      if (serverAtts.isNotEmpty) {
        final nextAtts = <Map<String, dynamic>>[];
        for (var i = 0; i < serverAtts.length; i++) {
          final att = Map<String, dynamic>.from(serverAtts[i]);
          if (i < pendingAttachments.length) {
            final local = pendingAttachments[i];
            final path = local['local_device_path']?.toString().trim() ?? '';
            if (path.isNotEmpty) att['local_device_path'] = path;
            final bytes = local['local_bytes'];
            if (isSafeUiPreviewBytes(bytes)) {
              att['local_bytes'] = bytes;
            }
          }
          nextAtts.add(att);
        }
        merged['attachments'] = nextAtts;
      }
    }

    if (ChatLocalStore.isSupported) {
      await ChatLocalStore.instance.deleteMessages(threadId, [tempId]);
      await ChatLocalStore.instance.upsertMessage(merged);
      return;
    }
    final existing =
        await FamilyChatLocalCache.readThreadMessages(threadId) ?? [];
    final withoutTemp =
        existing.where((m) => chatAsInt(m['id']) != tempId).toList();
    await FamilyChatLocalCache.saveThreadMessages(
      threadId,
      chatUpsertMessage(withoutTemp, merged),
    );
  }

  static Future<void> markPendingFailed({
    required int threadId,
    required int tempId,
  }) async {
    if (ChatLocalStore.isSupported) {
      final rows = await ChatLocalStore.instance.readMessages(threadId);
      final idx = rows.indexWhere((m) => chatAsInt(m['id']) == tempId);
      if (idx < 0) return;
      final next = Map<String, dynamic>.from(rows[idx]);
      next['read_status'] = 'failed';
      next['_pending'] = true;
      await ChatLocalStore.instance.upsertMessage(next);
      return;
    }
    final existing =
        await FamilyChatLocalCache.readThreadMessages(threadId) ?? [];
    final next = existing.map((m) {
      if (chatAsInt(m['id']) != tempId) return m;
      return {
        ...m,
        'read_status': 'failed',
        '_pending': true,
      };
    }).toList();
    await FamilyChatLocalCache.saveThreadMessages(threadId, next);
  }

  /// Resolve → compress → upload → send → replace temp row.
  static Future<void> deliver({
    required FamilyChatRepository repo,
    required int threadId,
    required int tempId,
    required String caption,
    required List<ShareAttachmentData> pendingAttachments,
    required List<Map<String, dynamic>> optimisticAttachmentMaps,
  }) async {
    final resolved = <ShareAttachmentData>[];
    for (var i = 0; i < pendingAttachments.length; i++) {
      resolved.add(
        await resolveShareAttachmentBytes(pendingAttachments[i], index: i),
      );
    }

    final attachmentIds = <int>[];
    for (final att in resolved) {
      Uint8List bytes = Uint8List.fromList(att.bytes);
      var filename = att.filename;
      var contentType = att.contentType;

      if (att.isImage && bytes.isNotEmpty) {
        try {
          final draft = await prepareImageUploadDraft(
            originalBytes: bytes,
            filename: filename,
            contentType: contentType,
            localPath: att.localPath,
          );
          bytes = draft.bytesForUpload;
          filename = draft.filename;
          contentType = draft.contentType;
        } catch (_) {
          // Keep original bytes.
        }
      } else if (att.isVideo && bytes.isNotEmpty) {
        try {
          final draft = await prepareVideoUploadDraft(
            originalBytes: bytes,
            filename: filename,
            contentType: contentType,
            localPath: att.localPath,
          );
          if (draft.canUpload) {
            bytes = draft.bytesForUpload;
            filename = draft.filename;
            contentType = draft.contentType;
          }
        } catch (_) {}
      }

      final uploaded = await repo.uploadChatAttachmentBytes(
        threadId,
        bytes: bytes,
        filename: filename,
        contentType: contentType,
      );
      final id = chatAsInt(uploaded['id']);
      if (id == null) continue;
      attachmentIds.add(id);
      final path = att.localPath?.trim() ?? '';
      if (path.isNotEmpty && (att.isImage || att.isVideo)) {
        await MediaLocalIndex.saveOutgoing(
          attachmentId: id,
          localPath: path,
          filename: filename,
          kind: att.isVideo ? 'video' : 'image',
        );
      }
    }

    final sent = await repo.sendThreadMessage(
      threadId,
      body: caption.isEmpty ? null : caption,
      attachmentIds: attachmentIds.isEmpty ? null : attachmentIds,
    );
    await replacePendingMessage(
      threadId: threadId,
      tempId: tempId,
      serverMessage: Map<String, dynamic>.from(sent),
      pendingAttachments: optimisticAttachmentMaps,
    );
    if (ChatSyncService.isSupported) {
      await ChatSyncService.instance.syncThread(threadId);
    }
  }
}
