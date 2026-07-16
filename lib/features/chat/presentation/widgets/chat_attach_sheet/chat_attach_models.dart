import 'dart:typed_data';

enum ChatAttachMode { gallery, file, location }

/// Выбранный элемент в шторке вложений (ещё до сжатия/отправки).
class ChatAttachSelectionItem {
  ChatAttachSelectionItem({
    required this.id,
    required this.filename,
    required this.bytes,
    required this.kind,
    this.contentType,
    this.thumbnailBytes,
    this.localPath,
    this.assetId,
  });

  final String id;
  final String filename;
  final Uint8List bytes;
  final Uint8List? thumbnailBytes;
  final String? contentType;
  final String? localPath;
  final String? assetId;

  /// image | video | file
  final String kind;

  Uint8List get previewBytes => thumbnailBytes ?? bytes;
}
