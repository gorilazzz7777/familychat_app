import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/local_device_file.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/network/chat_network_link.dart';
import '../../../core/settings/app_settings.dart';
import '../../familychat/data/familychat_repository.dart';
import '../presentation/widgets/chat_image_album.dart';
import 'chat_realtime_utils.dart';
import 'chat_voice_utils.dart';

enum ChatMediaDownloadCategory {
  photo,
  video,
  file,
  voice,
}

abstract final class ChatMediaAutoDownloadPolicy {
  static ChatMediaDownloadCategory categoryFor(
    Map<String, dynamic> attachment, {
    Map<String, dynamic> messageMetadata = const {},
  }) {
    if (isVoiceAttachment(attachment, messageMetadata: messageMetadata)) {
      return ChatMediaDownloadCategory.voice;
    }
    final kind = attachment['kind']?.toString();
    if (kind == 'video' || isVideoAttachment(attachment)) {
      return ChatMediaDownloadCategory.video;
    }
    if (chatAttachmentLooksLikeImage(attachment)) {
      return ChatMediaDownloadCategory.photo;
    }
    return ChatMediaDownloadCategory.file;
  }

  static bool shouldAutoDownload({
    required FamilyChatAppSettings settings,
    required ChatNetworkLinkKind network,
    required Map<String, dynamic> attachment,
    Map<String, dynamic> messageMetadata = const {},
  }) {
    if (network == ChatNetworkLinkKind.offline) return false;
    final onWifi = network == ChatNetworkLinkKind.wifi ||
        network == ChatNetworkLinkKind.unknown;
    final onMobile = network == ChatNetworkLinkKind.mobile;

    final category = categoryFor(
      attachment,
      messageMetadata: messageMetadata,
    );
    return switch (category) {
      ChatMediaDownloadCategory.photo =>
        (onWifi && settings.chatAutoDownloadPhotosWifi) ||
            (onMobile && settings.chatAutoDownloadPhotosMobile),
      ChatMediaDownloadCategory.video =>
        (onWifi && settings.chatAutoDownloadVideosWifi) ||
            (onMobile && settings.chatAutoDownloadVideosMobile),
      ChatMediaDownloadCategory.file =>
        (onWifi && settings.chatAutoDownloadFilesWifi) ||
            (onMobile && settings.chatAutoDownloadFilesMobile),
      ChatMediaDownloadCategory.voice =>
        (onWifi && settings.chatAutoDownloadVoiceWifi) ||
            (onMobile && settings.chatAutoDownloadVoiceMobile),
    };
  }

  static bool isLocallyAvailable({
    required int threadId,
    required Map<String, dynamic> attachment,
  }) {
    MediaLocalIndex.hydrateAttachment(attachment);

    final localPath = galleryLocalDevicePath(attachment);
    if (localPath.isNotEmpty && localDeviceFileExists(localPath)) return true;
    if (isSafeUiPreviewBytes(attachment['local_bytes'])) return true;

    final attachmentId = chatAsInt(attachment['id']);
    if (attachmentId != null && attachmentId > 0) {
      final cached = FamilyChatRepository.peekChatAttachmentBytes(
        threadId,
        attachmentId,
      );
      if (cached != null && cached.isNotEmpty) return true;
    }

    return false;
  }

  /// Можно воспроизвести/открыть по URL без полной загрузки в байты.
  static bool hasRemoteContentUrl({
    required Map<String, dynamic> attachment,
  }) {
    final attachmentId = chatAsInt(attachment['id']);
    if (attachmentId != null && attachmentId > 0) return true;
    final fileUrl = attachment['file_url']?.toString().trim() ?? '';
    if (fileUrl.isNotEmpty) return true;
    final url = attachment['url']?.toString().trim() ?? '';
    return url.isNotEmpty;
  }
}
