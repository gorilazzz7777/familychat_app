import 'dart:io';
import 'dart:typed_data';

import 'package:share_handler/share_handler.dart';

import '../../../core/debug/upload_image_exif_log.dart';
import 'chat_voice_utils.dart';
import 'ogg_container_duration.dart';
import 'share_attachment_bytes_reader.dart';
import 'share_attachment_data.dart';

Future<List<ShareAttachmentData>> loadShareAttachments(SharedMedia media) async {
  final result = <ShareAttachmentData>[];
  final attachments = media.attachments ?? const [];
  for (var i = 0; i < attachments.length; i++) {
    final attachment = attachments[i];
    final path = attachment?.path;
    if (path == null || path.isEmpty) continue;
    final file = File(path);
    if (!await file.exists()) continue;
    final filename = _filenameFromPath(path);
    final contentType = _contentTypeFor(filename, attachment?.type);
    final isImage = attachment?.type == SharedAttachmentType.image ||
        (contentType?.startsWith('image/') ?? false);
    final isVideo = attachment?.type == SharedAttachmentType.video ||
        (contentType?.startsWith('video/') ?? false);
    var isAudio = !isImage &&
        !isVideo &&
        (attachment?.type == SharedAttachmentType.audio ||
            looksLikeVoiceShare(filename: filename, contentType: contentType));
    Uint8List? audioBytes;
    int? durationMs;
    if (!isImage && !isVideo) {
      try {
        if (isAudio) {
          final raw = await file.readAsBytes();
          audioBytes = raw;
          durationMs = oggContainerDurationMs(raw);
          if (bytesLookLikeOgg(raw)) isAudio = true;
        } else {
          final raf = await file.open();
          try {
            final head = await raf.read(4);
            if (bytesLookLikeOgg(head)) {
              isAudio = true;
              await raf.setPosition(0);
              audioBytes = await raf.read(await file.length());
              durationMs = oggContainerDurationMs(audioBytes);
            }
          } finally {
            await raf.close();
          }
        }
      } catch (_) {}
    }
    result.add(
      ShareAttachmentData(
        filename: filename,
        contentType: isAudio
            ? (contentType ??
                voiceContentTypeForExtension(
                  voiceFilenameExtension(filename, contentType: contentType),
                ))
            : contentType,
        isImage: isImage,
        isVideo: isVideo,
        isAudio: isAudio,
        durationMs: durationMs,
        localPath: path,
        bytes: audioBytes ?? const [],
      ),
    );
  }
  return result;
}

Future<ShareAttachmentData> resolveShareAttachmentBytes(
  ShareAttachmentData attachment, {
  required int index,
}) async {
  final path = attachment.localPath;
  if (path == null || path.isEmpty) return attachment;
  final file = File(path);
  if (!await file.exists()) return attachment;
  if (attachment.bytes.isNotEmpty) return attachment;
  final fallbackBytes = await file.readAsBytes();
  final loaded = await readShareAttachmentBytes(
    index: index,
    fallbackBytes: fallbackBytes,
    filename: attachment.filename,
  );
  if (attachment.isImage) {
    await logUploadImageExifDiagnostics(
      bytes: loaded.bytes,
      filename: attachment.filename,
      sourcePath: path,
      readVia: loaded.readVia,
    );
  }
  var contentType = attachment.contentType;
  var isAudio = attachment.isAudio ||
      looksLikeVoiceShare(
        filename: attachment.filename,
        contentType: contentType,
        bytes: loaded.bytes,
      );
  if (isAudio) {
    contentType ??= voiceContentTypeForExtension(
      voiceFilenameExtension(attachment.filename, contentType: contentType),
    );
  }
  return ShareAttachmentData(
    bytes: loaded.bytes,
    filename: attachment.filename,
    contentType: contentType,
    isImage: attachment.isImage,
    isVideo: attachment.isVideo,
    isAudio: isAudio,
    durationMs: attachment.durationMs ?? oggContainerDurationMs(loaded.bytes),
    localPath: attachment.localPath,
  );
}

Future<ShareAttachmentData> resolveLoadedShareAttachmentBytes(
  ShareAttachmentData attachment, {
  required int index,
}) =>
    resolveShareAttachmentBytes(attachment, index: index);

Future<void> finishLoadedShareAttachmentRead() =>
    clearPendingShareAttachmentUris();


String _filenameFromPath(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  final name = parts.isNotEmpty ? parts.last : 'file';
  return name.isEmpty ? 'file' : name;
}

String? _contentTypeFor(String filename, SharedAttachmentType? type) {
  switch (type) {
    case SharedAttachmentType.image:
      return _contentTypeFromName(filename) ?? 'image/jpeg';
    case SharedAttachmentType.video:
      return _contentTypeFromName(filename) ?? 'video/mp4';
    case SharedAttachmentType.audio:
      return _contentTypeFromName(filename) ?? 'audio/ogg';
    case SharedAttachmentType.file:
    case null:
      return _contentTypeFromName(filename) ?? 'application/octet-stream';
  }
}

String? _contentTypeFromName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.txt')) return 'text/plain';
  if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
  if (lower.endsWith('.opus')) return 'audio/opus';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.wav')) return 'audio/wav';
  return null;
}
