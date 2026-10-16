import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/presentation/widgets/chat_image_viewer.dart';
import '../../chat/presentation/widgets/chat_link_item_actions.dart';
import '../tdlib_local_file.dart';
import '../telegram_tdlib_providers.dart';
import '../telegram_tdlib_service.dart';

/// Grid tile for TG profile/chat info «Галерея»: minithumb + soft chat-quality
/// file, kicks a foreground download, and opens fullscreen viewer on tap.
class TelegramSheetMediaThumb extends ConsumerStatefulWidget {
  const TelegramSheetMediaThumb({
    super.key,
    required this.message,
    this.gallery = const [],
    this.onGoToMessage,
  });

  final TdlibMessage message;
  /// Full sheet media list — enables swipe between items in the viewer.
  final List<TdlibMessage> gallery;
  final Future<void> Function(int messageId)? onGoToMessage;

  @override
  ConsumerState<TelegramSheetMediaThumb> createState() =>
      _TelegramSheetMediaThumbState();
}

class _TelegramSheetMediaThumbState
    extends ConsumerState<TelegramSheetMediaThumb> {
  bool _queued = false;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _kickDownload());
  }

  @override
  void didUpdateWidget(covariant TelegramSheetMediaThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id) {
      _queued = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _kickDownload());
    }
  }

  void _kickDownload() {
    if (!mounted || _queued) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    final path = svc.resolvedPhotoPath(widget.message) ??
        _videoThumbPath(svc, widget.message);
    if (path != null && path.isNotEmpty) return;
    _queued = true;
    unawaited(svc.ensureSheetMediaPreview(widget.message));
  }

  static String? _videoThumbPath(TelegramTdlibService svc, TdlibMessage m) {
    final local = m.videoThumbLocalPath;
    if (local != null && local.isNotEmpty) return local;
    final id = m.videoThumbFileId;
    if (id == null) return null;
    return svc.cachedFilePath(id);
  }

  static Map<String, dynamic> _attachmentFor(
    TelegramTdlibService svc,
    TdlibMessage m,
  ) {
    if (m.isVideo && !m.isVideoNote) {
      final fileId = m.videoFileId;
      final path = m.videoLocalPath ??
          (fileId == null ? null : svc.cachedFilePath(fileId));
      final thumbPath = m.videoThumbLocalPath ??
          (m.videoThumbFileId == null
              ? null
              : svc.cachedFilePath(m.videoThumbFileId!));
      final thumbBytes =
          m.videoThumbBytes != null && m.videoThumbBytes!.isNotEmpty
              ? Uint8List.fromList(m.videoThumbBytes!)
              : null;
      return {
        'id': fileId ?? m.id,
        'kind': 'video',
        'content_type': m.isAnimation ? 'image/gif' : 'video/mp4',
        'filename':
            '${m.isAnimation ? 'animation' : 'video'}_${m.id}.${m.isAnimation ? 'gif' : 'mp4'}',
        'skip_age_defer': true,
        'force_fullscreen': true,
        if (fileId != null && fileId > 0) 'tdlib_file_id': fileId,
        if (path != null && path.isNotEmpty) 'video_local_path': path,
        if (thumbPath != null && thumbPath.isNotEmpty)
          'thumbnail_local_path': thumbPath,
        if (thumbBytes != null) 'thumbnail_bytes': thumbBytes,
        if (m.videoDurationMs != null && m.videoDurationMs! > 0)
          'duration_ms': m.videoDurationMs,
        if (m.videoWidth != null && m.videoWidth! > 0) 'width': m.videoWidth,
        if (m.videoHeight != null && m.videoHeight! > 0) 'height': m.videoHeight,
      };
    }

    final path = svc.resolvedPhotoPath(m);
    final fileId = m.photoRemoteId ??
        (m.photoFallbackFileIds.isNotEmpty
            ? m.photoFallbackFileIds.first
            : null);
    final thumbBytes = m.photoThumbBytes != null && m.photoThumbBytes!.isNotEmpty
        ? Uint8List.fromList(m.photoThumbBytes!)
        : null;
    return {
      'id': fileId ?? m.id,
      'kind': 'image',
      'content_type': 'image/jpeg',
      'filename': 'tg_${fileId ?? m.id}.jpg',
      'skip_age_defer': true,
      if (fileId != null && fileId > 0) 'tdlib_file_id': fileId,
      if (path != null && path.isNotEmpty) 'local_device_path': path,
      if (m.photoWidth != null && m.photoWidth! > 0) 'width': m.photoWidth,
      if (m.photoHeight != null && m.photoHeight! > 0) 'height': m.photoHeight,
      if ((path == null || path.isEmpty) && thumbBytes != null) ...{
        'local_bytes': thumbBytes,
        'thumbnail_bytes': thumbBytes,
      },
    };
  }

  Future<void> _showActions() async {
    if (_opening || !mounted) return;
    final goTo = widget.onGoToMessage;
    final messageId = widget.message.id;
    await showChatLinkItemActions(
      context,
      openTitle: 'Открыть',
      openIcon: LucideIcons.maximize_2,
      onOpen: () => _openFullscreen(),
      onGoToMessage: messageId > 0 && goTo != null
          ? () => goToChatInfoMessage(
                context,
                messageId: messageId,
                onGoToMessage: goTo,
              )
          : null,
    );
  }

  Future<void> _openFullscreen() async {
    if (_opening || !mounted) return;
    setState(() => _opening = true);
    final svc = ref.read(telegramTdlibServiceProvider);
    final m = widget.message;
    try {
      final play = _attachmentFor(svc, m);
      final isVideo = play['kind']?.toString() == 'video';
      final fileId = int.tryParse(play['id']?.toString() ?? '') ?? 0;

      if (isVideo) {
        var videoPath = play['video_local_path']?.toString() ?? '';
        if (videoPath.isEmpty && fileId > 0) {
          await svc.preemptForUserTap(
            fileId: fileId,
            chatId: m.chatId,
            reason: 'tap:video:$fileId',
          );
          final path = await svc.ensureFileLocal(
            fileId,
            priority: TelegramTdlibService.prioFocused,
            reason: 'tap:video:$fileId',
            waitFor: const Duration(minutes: 10),
          );
          if (path == null || path.isEmpty) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Не удалось загрузить видео')),
            );
            return;
          }
          videoPath = path;
        }
        play['video_local_path'] = videoPath;
        play.remove('local_device_path');
      } else if (fileId > 0) {
        await svc.preemptForUserTap(
          fileId: fileId,
          chatId: m.chatId,
          reason: 'tap:photo:$fileId',
        );
        final path = await svc.ensureFileLocal(
          fileId,
          priority: TelegramTdlibService.prioFocused,
          reason: 'tap:photo:$fileId',
          waitFor: const Duration(seconds: 45),
        );
        if (path != null && path.isNotEmpty) {
          play['local_device_path'] = path;
          play.remove('local_bytes');
          play.remove('thumbnail_bytes');
        }
      }

      if (!mounted) return;
      final galleryMsgs =
          widget.gallery.isNotEmpty ? widget.gallery : <TdlibMessage>[m];
      final galleryAtts = [
        for (final gm in galleryMsgs) _attachmentFor(svc, gm),
      ];
      // Stamp the opened item so the viewer doesn't keep a stale empty path.
      final playId = play['id']?.toString();
      final stamped = [
        for (final raw in galleryAtts)
          () {
            final copy = Map<String, dynamic>.from(raw);
            if (playId != null &&
                playId.isNotEmpty &&
                copy['id']?.toString() == playId) {
              copy.addAll(play);
            }
            return copy;
          }(),
      ];

      await ChatImageViewer.open(
        context,
        imageUrl: '',
        threadId: m.chatId,
        attachmentId: fileId > 0 ? fileId : null,
        messageId: m.id,
        filename: play['filename']?.toString(),
        attachment: play,
        galleryAttachments: stamped.length >= 2 ? stamped : null,
        enableFaceTag: false,
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when downloads complete / paths land.
    ref.watch(telegramTdlibServiceProvider);
    final svc = ref.read(telegramTdlibServiceProvider);
    final m = widget.message;
    final path = svc.resolvedPhotoPath(m) ?? _videoThumbPath(svc, m);
    final thumb = m.photoThumbBytes ?? m.videoNoteThumbBytes ?? m.videoThumbBytes;
    final theme = Theme.of(context);

    Widget image;
    if (path != null && path.isNotEmpty) {
      image = tdlibLocalFileImage(path, fit: BoxFit.cover);
    } else if (thumb != null && thumb.isNotEmpty) {
      image = Image.memory(
        thumb is Uint8List ? thumb : Uint8List.fromList(thumb),
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      image = ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            m.isVideo ? LucideIcons.video : LucideIcons.image,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _opening ? null : () => unawaited(_openFullscreen()),
        onLongPress: _opening ? null : () => unawaited(_showActions()),
        borderRadius: BorderRadius.circular(6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              if (m.isVideo)
                const Align(
                  alignment: Alignment.center,
                  child: Icon(
                    LucideIcons.play,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              if (_opening)
                ColoredBox(
                  color: Colors.black26,
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
