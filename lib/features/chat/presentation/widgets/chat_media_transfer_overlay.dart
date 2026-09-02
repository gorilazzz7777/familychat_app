import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_attachment_download_manager.dart';
import '../../data/chat_media_auto_download.dart';
import '../../data/chat_media_providers.dart';
import '../../data/chat_media_upload_tracker.dart';
import '../../data/chat_realtime_utils.dart';
import '../../../../core/media/media_local_index.dart';

/// Оверлей прогресса / отмены / ручной загрузки поверх превью медиа.
class ChatMediaTransferOverlay extends ConsumerWidget {
  const ChatMediaTransferOverlay({
    super.key,
    required this.child,
    this.threadId,
    this.attachment,
    this.uploadMessageId,
    this.onCancelUpload,
    this.onDownloadTap,
    this.borderRadius,
    this.showWhenUploading = true,
    this.showWhenDownloading = true,
    this.showManualDownload = true,
  });

  final Widget child;
  final int? threadId;
  final Map<String, dynamic>? attachment;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;
  final VoidCallback? onDownloadTap;
  final BorderRadius? borderRadius;
  final bool showWhenUploading;
  final bool showWhenDownloading;
  final bool showManualDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploadId = uploadMessageId;
    if (uploadId != null && showWhenUploading) {
      return ListenableBuilder(
        listenable: ref.watch(chatMediaUploadTrackerProvider),
        builder: (context, _) {
          final upload = ref.read(chatMediaUploadTrackerProvider).stateFor(uploadId);
          if (!upload.active) return child;
          return _stack(
            context,
            child: child,
            progress: upload.progress,
            onCancel: onCancelUpload,
          );
        },
      );
    }

    final tid = threadId;
    final att = attachment;
    if (tid == null || att == null) {
      return child;
    }
    final attachmentId = chatAsInt(att['id']);
    if (attachmentId == null || attachmentId <= 0) {
      return child;
    }

    return ListenableBuilder(
      listenable: ref.watch(chatAttachmentDownloadManagerProvider),
      builder: (context, _) {
        final manager = ref.read(chatAttachmentDownloadManagerProvider);
        MediaLocalIndex.hydrateAttachment(att);
        final locallyAvailable = ChatMediaAutoDownloadPolicy.isLocallyAvailable(
          threadId: tid,
          attachment: att,
        );

        final state = manager.stateFor(tid, attachmentId);
        if (locallyAvailable) {
          if (state.phase == ChatAttachmentDownloadPhase.downloading) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              ref
                  .read(chatAttachmentDownloadManagerProvider)
                  .markLocallyAvailable(tid, attachmentId);
            });
          }
          return child;
        }

        final hideManualPrompt = !showManualDownload || locallyAvailable;
        if (state.phase != ChatAttachmentDownloadPhase.downloading &&
            (hideManualPrompt ||
                locallyAvailable ||
                state.phase == ChatAttachmentDownloadPhase.completed)) {
          return child;
        }
        if (state.phase == ChatAttachmentDownloadPhase.downloading &&
            showWhenDownloading) {
          return _stack(
            context,
            child: child,
            progress: state.progress,
            onCancel: () => manager.cancelDownload(tid, attachmentId),
          );
        }
        if (!hideManualPrompt && state.needsManualTap) {
          return Stack(
            fit: StackFit.passthrough,
            children: [
              child,
              Positioned.fill(
                child: Material(
                  color: Colors.black.withValues(alpha: 0.28),
                  child: InkWell(
                    onTap: onDownloadTap,
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.download_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return child;
      },
    );
  }

  Widget _stack(
    BuildContext context, {
    required Widget child,
    required double progress,
    VoidCallback? onCancel,
  }) {
    const ringSize = 56.0;
    const strokeWidth = 3.0;
    final innerSize = ringSize - strokeWidth * 2;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: ClipRRect(
            borderRadius: borderRadius ?? BorderRadius.zero,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.35),
              child: Center(
                child: SizedBox(
                  width: ringSize,
                  height: ringSize,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: ringSize,
                        height: ringSize,
                        child: CircularProgressIndicator(
                          value: progress > 0 ? progress : null,
                          strokeWidth: strokeWidth,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      if (onCancel != null)
                        _CancelButton(
                          onTap: onCancel,
                          size: innerSize,
                        )
                      else
                        Text(
                          '${(progress * 100).clamp(0, 100).round()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({
    required this.onTap,
    this.size = 44,
  });

  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            Icons.close_rounded,
            color: Colors.white,
            size: size * 0.48,
          ),
        ),
      ),
    );
  }
}
