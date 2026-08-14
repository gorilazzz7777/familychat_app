import 'gallery_media_utils.dart';

class LocalMediaRef {
  const LocalMediaRef({
    required this.path,
    this.assetId,
    required this.kind,
    required this.serverUrl,
  });

  final String path;
  final String? assetId;
  final String kind;
  final String serverUrl;

  Map<String, dynamic> toPayloadFields() => {
        'local_device_path': path,
        if (assetId != null && assetId!.isNotEmpty) 'local_asset_id': assetId,
        'local_media_kind': kind,
        'server_url': serverUrl,
      };
}

abstract final class GalleryDeviceMediaStore {
  static String? existingLocalPath(Map<String, dynamic> attachment) {
    final path = attachment['local_device_path']?.toString().trim() ?? '';
    return path.isEmpty ? null : path;
  }

  static Future<Map<String, dynamic>?> linkExistingInAlbum(
    Map<String, dynamic> attachment,
  ) async =>
      null;

  static Future<Map<String, dynamic>?> ensureForAttachment(
    Map<String, dynamic> attachment, {
    String? albumId,
    bool downloadVideo = true,
    bool allowCopyToPhoneAlbum = true,
  }) async =>
      null;

  static Future<LocalMediaRef?> ensureLocalMedia({
    required String serverUrl,
    required String mediaId,
    String? albumId,
    bool isVideo = false,
    String? filename,
    bool allowCopyToPhoneAlbum = true,
  }) async =>
      null;

  static Future<void> deleteFromPhoneAlbum({
    String? assetId,
    String? filename,
  }) async {}

  static bool isGalleryMedia(Map<String, dynamic> attachment) =>
      isImageAttachment(attachment) || isVideoAttachment(attachment);
}
