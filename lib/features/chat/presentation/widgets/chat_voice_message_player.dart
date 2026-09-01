import 'dart:async';

import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/local_device_file.dart';
import '../../../../core/network/chat_network_link.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/settings/app_settings_controller.dart';
import '../../data/chat_media_providers.dart';
import '../../data/chat_realtime_utils.dart';
import '../../data/chat_voice_transcription_prefs.dart';
import '../../data/chat_voice_utils.dart';
import 'chat_media_transfer_overlay.dart';
import 'chat_network_image.dart';

class ChatVoiceMessagePlayer extends ConsumerStatefulWidget {
  const ChatVoiceMessagePlayer({
    super.key,
    required this.threadId,
    required this.attachment,
    required this.isMine,
    this.durationMs,
    this.transcript,
    this.canToggleTranscript = false,
    this.textColor,
    this.metaColor,
    this.messageMetadata = const {},
    this.uploadMessageId,
    this.onCancelUpload,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final bool isMine;
  final int? durationMs;
  final String? transcript;
  final bool canToggleTranscript;
  final Color? textColor;
  final Color? metaColor;
  final Map<String, dynamic> messageMetadata;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;

  @override
  ConsumerState<ChatVoiceMessagePlayer> createState() =>
      _ChatVoiceMessagePlayerState();
}

class _ChatVoiceMessagePlayerState extends ConsumerState<ChatVoiceMessagePlayer> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    final durationMs = widget.durationMs;
    if (durationMs != null && durationMs > 0) {
      _total = Duration(milliseconds: durationMs);
    }
    _scheduleAutoDownload();
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state == PlayerState.playing);
    });
    _player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _total = duration);
    });
    _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void _scheduleAutoDownload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final attachmentId = chatAsInt(widget.attachment['id']);
      if (attachmentId == null || attachmentId <= 0) return;
      final settings = ref.read(appSettingsProvider);
      final network = ref.read(chatNetworkLinkProvider).value ??
          ChatNetworkLinkKind.unknown;
      unawaited(
        ref.read(chatAttachmentDownloadManagerProvider).maybeAutoDownload(
              threadId: widget.threadId,
              attachment: widget.attachment,
              settings: settings,
              network: network,
              messageMetadata: widget.messageMetadata,
            ),
      );
    });
  }

  Future<void> _togglePlayback() async {
    if (_playing) {
      await _player.pause();
      return;
    }

    final mime = voicePlaybackMimeType(
      filename: widget.attachment['filename']?.toString(),
      contentType: widget.attachment['content_type']?.toString(),
    );
    final localPath = galleryLocalDevicePath(widget.attachment);
    if (localPath.isNotEmpty && localDeviceFileExists(localPath)) {
      await _player.play(DeviceFileSource(localPath, mimeType: mime));
      return;
    }

    final localBytes = widget.attachment['local_bytes'];
    if (localBytes is Uint8List && localBytes.isNotEmpty) {
      await _player.play(BytesSource(localBytes, mimeType: mime));
      return;
    }

    final repo = ref.read(familychatRepositoryProvider);
    final url = chatAttachmentImageUrl(
      repo: repo,
      threadId: widget.threadId,
      attachment: widget.attachment,
    );
    if (url.isNotEmpty) {
      await _player.play(UrlSource(url, mimeType: mime));
      return;
    }

    final attachmentId = chatAsInt(widget.attachment['id']);
    if (attachmentId == null) return;
    final bytes = await ref.read(chatAttachmentDownloadManagerProvider).startDownload(
          threadId: widget.threadId,
          attachmentId: attachmentId,
          manual: true,
        );
    if (bytes == null || bytes.isEmpty) return;
    await _player.play(BytesSource(bytes, mimeType: mime));
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.textColor ?? Theme.of(context).colorScheme.onSurface;
    final metaColor = widget.metaColor ?? textColor.withValues(alpha: 0.75);
    final transcript = widget.transcript?.trim();
    final hasTranscript =
        transcript != null && transcript.isNotEmpty && widget.canToggleTranscript;
    final preferText = ref.watch(voiceMessagePreferTextProvider);
    final showText = hasTranscript && preferText;

    final totalMs = _total.inMilliseconds > 0
        ? _total.inMilliseconds
        : (widget.durationMs ?? 0);
    final progress = totalMs > 0
        ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final label = _playing || _position.inMilliseconds > 0
        ? formatVoiceDuration(_position.inMilliseconds)
        : formatVoiceDuration(totalMs);

    final toggle = hasTranscript
        ? IconButton(
            tooltip: showText ? 'Показать голос' : 'Показать текст',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              ref.read(voiceMessagePreferTextProvider.notifier).toggle();
            },
            icon: Icon(
              showText ? Icons.graphic_eq_rounded : Icons.notes_rounded,
              size: 20,
              color: metaColor,
            ),
          )
        : null;

    if (showText) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              transcript,
              style: TextStyle(color: textColor, height: 1.35),
            ),
          ),
          if (toggle != null) toggle,
        ],
      );
    }

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: _togglePlayback,
          icon: Icon(
            _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: textColor,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 132,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: metaColor.withValues(alpha: 0.25),
                  color: textColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(color: metaColor, fontSize: 12),
              ),
            ],
          ),
        ),
        if (toggle != null) ...[
          const SizedBox(width: 2),
          toggle,
        ],
      ],
    );

    return ChatMediaTransferOverlay(
      threadId: widget.threadId,
      attachment: widget.attachment,
      uploadMessageId: widget.uploadMessageId,
      onCancelUpload: widget.onCancelUpload,
      onDownloadTap: _togglePlayback,
      child: row,
    );
  }
}
