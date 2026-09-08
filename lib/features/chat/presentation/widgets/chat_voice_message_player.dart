import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/local_device_file.dart';
import '../../../../core/media/media_local_index.dart';
import '../../../../core/network/chat_network_link.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/settings/app_settings_controller.dart';
import '../../data/chat_attachment_download_manager.dart';
import '../../data/chat_media_auto_download.dart';
import '../../data/chat_media_providers.dart';
import '../../data/chat_realtime_utils.dart';
import '../../data/chat_voice_playback_coordinator.dart';
import '../../data/chat_voice_transcription_prefs.dart';
import '../../data/chat_voice_utils.dart';
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
  late final ChatVoicePlayerHandle _handle;
  bool _playing = false;
  bool _preparing = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  double _rate = ChatVoicePlaybackCoordinator.instance.playbackRate;
  StreamSubscription<void>? _completeSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;

  int? get _attachmentId => chatAsInt(widget.attachment['id']);

  @override
  void initState() {
    super.initState();
    final durationMs = widget.durationMs;
    if (durationMs != null && durationMs > 0) {
      _total = Duration(milliseconds: durationMs);
    }
    _handle = ChatVoicePlayerHandle(
      pauseIfPlaying: _pauseIfPlaying,
      playFromAutoplay: () => _togglePlayback(fromAutoplay: true),
      applyRate: _applyRate,
    );
    final id = _attachmentId;
    if (id != null && id > 0) {
      ChatVoicePlaybackCoordinator.instance.register(id, _handle);
    }
    _scheduleAutoDownload();
    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state == PlayerState.playing);
    });
    _durationSub = _player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _total = duration);
    });
    _positionSub = _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _completeSub = _player.onPlayerComplete.listen((_) async {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
      final id = _attachmentId;
      if (id != null && id > 0) {
        await ChatVoicePlaybackCoordinator.instance.notifyCompleted(id);
      }
    });
  }

  @override
  void dispose() {
    final id = _attachmentId;
    if (id != null && id > 0) {
      ChatVoicePlaybackCoordinator.instance.unregister(id, _handle);
    }
    unawaited(_stateSub?.cancel() ?? Future<void>.value());
    unawaited(_durationSub?.cancel() ?? Future<void>.value());
    unawaited(_positionSub?.cancel() ?? Future<void>.value());
    unawaited(_completeSub?.cancel() ?? Future<void>.value());
    _player.dispose();
    super.dispose();
  }

  Future<void> _pauseIfPlaying() async {
    if (!_playing) return;
    await _player.pause();
  }

  Future<void> _applyRate(double rate) async {
    _rate = rate;
    try {
      await _player.setPlaybackRate(rate);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _cycleSpeed() {
    final next = ChatVoicePlaybackCoordinator.instance.cyclePlaybackRate();
    unawaited(_applyRate(next));
  }

  void _scheduleAutoDownload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final attachmentId = _attachmentId;
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

  bool _isLocallyReady() {
    MediaLocalIndex.hydrateAttachment(widget.attachment);
    return ChatMediaAutoDownloadPolicy.isLocallyAvailable(
          threadId: widget.threadId,
          attachment: widget.attachment,
        ) ||
        ChatMediaAutoDownloadPolicy.hasRemoteContentUrl(
          attachment: widget.attachment,
        );
  }

  Future<void> _togglePlayback({bool fromAutoplay = false}) async {
    if (_preparing) return;
    if (_playing) {
      await _player.pause();
      return;
    }

    setState(() => _preparing = true);
    try {
      await _ensureMediaAudioContext();
      final mime = voicePlaybackMimeType(
        filename: widget.attachment['filename']?.toString(),
        contentType: widget.attachment['content_type']?.toString(),
      );

      final id = _attachmentId;
      if (id != null && id > 0) {
        await ChatVoicePlaybackCoordinator.instance.notifyStarted(id);
      }

      await _player.setPlaybackRate(_rate);

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

      final attachmentId = _attachmentId;
      if (attachmentId != null && attachmentId > 0) {
        final bytes =
            await ref.read(chatAttachmentDownloadManagerProvider).startDownload(
                  threadId: widget.threadId,
                  attachmentId: attachmentId,
                  manual: true,
                );
        if (bytes == null || bytes.isEmpty) return;
        await _player.play(BytesSource(bytes, mimeType: mime));
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
      }
    } catch (e, st) {
      debugPrint('voice playback failed: $e\n$st');
      if (!mounted) return;
      if (!fromAutoplay) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось воспроизвести голосовое')),
        );
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  /// Scrapbook ставит global AudioContext в sonification/ambient — голос молчит.
  Future<void> _ensureMediaAudioContext() async {
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gain,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {},
          ),
        ),
      );
    } catch (_) {}
  }

  Widget _buildPlayControl({
    required Color accent,
    required Color onAccent,
    required bool downloading,
    required bool uploading,
    required double transferProgress,
    required VoidCallback? onCancelTransfer,
  }) {
    final busy = _preparing || downloading || uploading;
    return Material(
      color: accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy
            ? onCancelTransfer
            : () => unawaited(_togglePlayback()),
        child: SizedBox(
          width: 40,
          height: 40,
          child: busy
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: CircularProgressIndicator(
                    value: transferProgress > 0 ? transferProgress : null,
                    strokeWidth: 2.4,
                    color: onAccent,
                    backgroundColor: onAccent.withValues(alpha: 0.25),
                  ),
                )
              : Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: onAccent,
                  size: 24,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor =
        widget.textColor ?? theme.colorScheme.onSurface;
    final metaColor =
        widget.metaColor ?? textColor.withValues(alpha: 0.72);
    final accent = widget.isMine
        ? Colors.white.withValues(alpha: 0.92)
        : theme.colorScheme.primary;
    final onAccent = widget.isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.onPrimary;

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
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () {
              ref.read(voiceMessagePreferTextProvider.notifier).toggle();
            },
            icon: Icon(
              showText ? Icons.graphic_eq_rounded : Icons.notes_rounded,
              size: 18,
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

    final uploadId = widget.uploadMessageId;
    final attachmentId = _attachmentId;
    final uploadTracker = ref.watch(chatMediaUploadTrackerProvider);
    final downloadManager = ref.watch(chatAttachmentDownloadManagerProvider);

    var downloading = false;
    var uploading = false;
    var transferProgress = 0.0;
    VoidCallback? onCancelTransfer;

    if (uploadId != null) {
      final upload = uploadTracker.stateFor(uploadId);
      if (upload.active) {
        uploading = true;
        transferProgress = upload.progress;
        onCancelTransfer = widget.onCancelUpload;
      }
    }

    if (!uploading &&
        attachmentId != null &&
        attachmentId > 0 &&
        !_isLocallyReady()) {
      final state =
          downloadManager.stateFor(widget.threadId, attachmentId);
      if (state.phase == ChatAttachmentDownloadPhase.downloading) {
        downloading = true;
        transferProgress = state.progress;
        onCancelTransfer = () =>
            downloadManager.cancelDownload(widget.threadId, attachmentId);
      }
    }

    final trackBg = metaColor.withValues(alpha: 0.22);
    final trackFg = textColor.withValues(alpha: 0.9);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
      child: Row(
        children: [
          _buildPlayControl(
            accent: accent,
            onAccent: onAccent,
            downloading: downloading,
            uploading: uploading,
            transferProgress: transferProgress,
            onCancelTransfer: onCancelTransfer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    activeTrackColor: trackFg,
                    inactiveTrackColor: trackBg,
                    thumbColor: trackFg,
                    overlayColor: trackFg.withValues(alpha: 0.12),
                    padding: EdgeInsets.zero,
                  ),
                  child: SizedBox(
                    height: 22,
                    child: Slider(
                      value: progress,
                      onChanged: totalMs <= 0
                          ? null
                          : (v) {
                              final ms = (v * totalMs).round();
                              setState(
                                () => _position = Duration(milliseconds: ms),
                              );
                            },
                      onChangeEnd: totalMs <= 0
                          ? null
                          : (v) async {
                              final ms = (v * totalMs).round();
                              await _player.seek(Duration(milliseconds: ms));
                            },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 2),
                  child: Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: metaColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      Material(
                        color: metaColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: _cycleSpeed,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            child: Text(
                              ChatVoicePlaybackCoordinator
                                  .instance.playbackRateLabel,
                              style: TextStyle(
                                color: textColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (toggle != null) ...[
                        const SizedBox(width: 2),
                        toggle,
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
