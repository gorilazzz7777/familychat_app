import 'package:familychat_app/core/network/chat_network_link.dart';
import 'package:familychat_app/core/settings/app_settings.dart';
import 'package:familychat_app/features/chat/data/chat_media_auto_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const settings = FamilyChatAppSettings();

  test('auto download photos enabled by default on wifi and mobile', () {
    expect(
      ChatMediaAutoDownloadPolicy.shouldAutoDownload(
        settings: settings,
        network: ChatNetworkLinkKind.wifi,
        attachment: const {'kind': 'image'},
      ),
      isTrue,
    );
    expect(
      ChatMediaAutoDownloadPolicy.shouldAutoDownload(
        settings: settings,
        network: ChatNetworkLinkKind.mobile,
        attachment: const {'kind': 'image'},
      ),
      isTrue,
    );
  });

  test('auto download respects disabled mobile photos', () {
    final disabled = settings.copyWith(chatAutoDownloadPhotosMobile: false);
    expect(
      ChatMediaAutoDownloadPolicy.shouldAutoDownload(
        settings: disabled,
        network: ChatNetworkLinkKind.mobile,
        attachment: const {'kind': 'image'},
      ),
      isFalse,
    );
    expect(
      ChatMediaAutoDownloadPolicy.shouldAutoDownload(
        settings: disabled,
        network: ChatNetworkLinkKind.wifi,
        attachment: const {'kind': 'image'},
      ),
      isTrue,
    );
  });

  test('voice attachments use voice policy', () {
    final disabled = settings.copyWith(chatAutoDownloadVoiceWifi: false);
    expect(
      ChatMediaAutoDownloadPolicy.shouldAutoDownload(
        settings: disabled,
        network: ChatNetworkLinkKind.wifi,
        attachment: const {'kind': 'audio', 'content_type': 'audio/ogg'},
        messageMetadata: const {
          'voice': {'duration_ms': 1200},
        },
      ),
      isFalse,
    );
  });
}
