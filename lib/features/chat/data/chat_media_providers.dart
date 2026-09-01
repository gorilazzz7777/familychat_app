import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/chat_network_link.dart';
import '../../../core/providers/app_providers.dart';
import 'chat_attachment_download_manager.dart';
import 'chat_media_upload_tracker.dart';

final chatAttachmentDownloadManagerProvider =
    ChangeNotifierProvider<ChatAttachmentDownloadManager>((ref) {
  return ChatAttachmentDownloadManager(
    ref.watch(familychatRepositoryProvider),
  );
});

final chatMediaUploadTrackerProvider =
    ChangeNotifierProvider<ChatMediaUploadTracker>((ref) {
  final tracker = ChatMediaUploadTracker();
  ChatMediaUploadTracker.shared = tracker;
  ref.onDispose(() {
    if (ChatMediaUploadTracker.shared == tracker) {
      ChatMediaUploadTracker.shared = null;
    }
  });
  return tracker;
});

final chatNetworkLinkProvider = StreamProvider<ChatNetworkLinkKind>((ref) {
  return ChatNetworkLink.watch();
});
