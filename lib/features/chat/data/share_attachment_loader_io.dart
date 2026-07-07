import 'dart:io';
import 'dart:typed_data';

import 'package:share_handler/share_handler.dart';

import '../../../core/debug/upload_image_exif_log.dart';
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
    final fallbackBytes = await file.readAsBytes();
    final bytes = await readShareAttachmentBytes(
          index: i,
          fallbackBytes: fallbackBytes,
        ) ??
        fallbackBytes;
    final filename = _filenameFromPath(path);
    final contentType = _contentTypeFor(filename, attachment?.type);
    final isImage = attachment?.type == SharedAttachmentType.image ||
        (contentType?.startsWith('image/') ?? false);
    if (isImage) {
      final readVia = bytes.length == fallbackBytes.length &&
              _bytesEqual(bytes, fallbackBytes)
          ? 'share_handler_cache'
          : 'share_intent_original_uri';
      await logUploadImageExifDiagnostics(
        bytes: bytes,
        filename: filename,
        sourcePath: path,
        readVia: readVia,
      );
    }
    result.add(
      ShareAttachmentData(
        bytes: bytes,
        filename: filename,
        contentType: contentType,
        isImage: isImage,
      ),
    );
  }
  await clearPendingShareAttachmentUris();
  return result;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

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
    case SharedAttachmentType.file:
    case SharedAttachmentType.audio:
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
  return null;
}
