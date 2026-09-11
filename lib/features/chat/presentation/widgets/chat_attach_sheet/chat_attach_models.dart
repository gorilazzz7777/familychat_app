import 'dart:typed_data';

import '../../../../../core/media/gallery_media_utils.dart';
import '../../../../../core/media/video_upload_pipeline.dart';

enum ChatAttachMode { gallery, file, location, familyGallery }

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
    this.assetFingerprint,
    this.geo,
  });

  final String id;
  final String filename;
  final Uint8List bytes;
  final Uint8List? thumbnailBytes;
  final String? contentType;
  final String? localPath;
  final String? assetId;
  /// Отпечаток ассета телефона для подсветки «уже добавляли» (особенно iOS).
  final String? assetFingerprint;
  /// GPS с телефона (PhotoKit / оригинал HEIC). iOS JPEG из `asset.file` GPS не содержит.
  final MediaGeo? geo;

  /// image | video | file
  final String kind;

  /// Только лёгкое превью для UI. Никогда не отдаём сырые байты видео/полный кадр.
  Uint8List get previewBytes =>
      safeUiPreviewBytes(
        thumbnailBytes: thumbnailBytes,
        bytes: bytes,
        kind: kind,
      ) ??
      Uint8List(0);
}
