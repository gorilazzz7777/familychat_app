import 'dart:io';

import 'package:share_handler/share_handler.dart';

import '../../../core/debug/upload_image_exif_log.dart';
import 'share_attachment_data.dart';

Future<List<ShareAttachmentData>> loadShareAttachments(SharedMedia media) async {
  final result = <ShareAttachmentData>[];
  for (final attachment in media.attachments ?? const []) {
    final path = attachment?.path;
    if (path == null || path.isEmpty) continue;
    final file = File(path);
    if (!await file.exists()) continue;
    final bytes = await file.readAsBytes();
    final filename = _filenameFromPath(path);
    final contentType = _contentTypeFor(filename, attachment?.type);
    final isImage = attachment?.type == SharedAttachmentType.image ||
        (contentType?.startsWith('image/') ?? false);
    if (isImage) {
      await logUploadImageExifDiagnostics(
        bytes: bytes,
        filename: filename,
        sourcePath: path,
        readVia: 'share_handler_path',
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
  return result;
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
