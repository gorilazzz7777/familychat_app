import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/audio/voice_playback_proximity_route.dart';
import '../../../../core/diagnostics/session_log.dart';
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
import '../../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../../telegram_tdlib/telegram_tdlib_service.dart';
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
    this.transcriptBusy = false,
    this.onRequestTranscript,
    this.maxWidth,
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
  /// TG SaluteSpeech: request in flight.
  final bool transcriptBusy;
  /// TG: tap sticky-note when there is no transcript yet.
  final VoidCallback? onRequestTranscript;
  /// Bubble content width — used when transcript is shown under the player
  /// (Max-style: expand to regular text-message width).
  final double? maxWidth;
  final Color? textColor;
  final Color? metaColor;
  final Map<String, dynamic> messageMetadata;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;

  @override
  ConsumerState<ChatVoiceMessagePlayer> createState() =>
      _ChatVoiceMessagePlayerState();
}

class _ChatVoiceMessagePlayerState extends ConsumerState<ChatVoiceMessagePlayer>
    with WidgetsBindingObserver {
  final _player = AudioPlayer();
  late final ChatVoicePlayerHandle _handle;
  bool _playing = false;
  bool _preparing = false;
  /// True while rebuilding the track after earpiece↔speaker (TG startAudioAgain).
  bool _routeRestarting = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  double _rate = ChatVoicePlaybackCoordinator.instance.playbackRate;
  Source? _activeSource;
  final Object _routeRestartToken = Object();
  StreamSubscription<void>? _completeSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  Duration? _lastLoggedPosition;
  DateTime? _lastPositionAt;
  HardwareKeyboard? _keyboard;
  bool _keyboardHooked = false;

  int? get _attachmentId => chatAsInt(widget.attachment['id']);

  void _voiceLog(String evt, [Map<String, Object?> fields = const {}]) {
    SessionLog.instance.event('voice.play', evt, {
      'att': _attachmentId,
      'thread': widget.threadId,
      'tdlib': _isTdlibVoice,
      'playing': _playing,
      'preparing': _preparing,
      'posMs': _position.inMilliseconds,
      'totalMs': _total.inMilliseconds,
      'rate': _rate,
      ...fields,
    });
  }

  bool get _isTdlibVoice =>
      widget.attachment['tdlib_file_id'] != null ||
      (widget.attachment['skip_age_defer'] == true &&
          widget.messageMetadata['source']?.toString() == 'telegram');

  int? get _tdlibFileId =>
      chatAsInt(widget.attachment['tdlib_file_id']) ??
      chatAsInt(widget.attachment['id']);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hookVolumeKeys(true);
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
      final playing = state == PlayerState.playing;
      final wasPlaying = _playing;
      _voiceLog('player_state', {
        'state': state.name,
        'wasPlaying': wasPlaying,
        'nowPlaying': playing,
        'routeRestarting': _routeRestarting,
      });
      setState(() => _playing = playing);
      if (_routeRestarting) return;
      if (playing && !wasPlaying) {
        VoicePlaybackProximityRoute.instance.attachRouteRestart(
          _routeRestartToken,
          _restartForAudioRoute,
        );
        unawaited(VoicePlaybackProximityRoute.instance.onPlaying());
      } else if (!playing && wasPlaying) {
        VoicePlaybackProximityRoute.instance
            .detachRouteRestart(_routeRestartToken);
        unawaited(VoicePlaybackProximityRoute.instance.onNotPlaying());
      }
    });
    _durationSub = _player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _total = duration);
    });
    _positionSub = _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      final prev = _lastLoggedPosition;
      final prevAt = _lastPositionAt;
      final now = DateTime.now();
      if (prev != null && prevAt != null) {
        final wallMs = now.difference(prevAt).inMilliseconds;
        final mediaDelta = position.inMilliseconds - prev.inMilliseconds;
        // Stall / jump / rewind while supposedly playing.
        if (_playing &&
            (mediaDelta.abs() > 600 ||
                (wallMs >= 700 && mediaDelta.abs() < 40))) {
          _voiceLog('position_anomaly', {
            'fromMs': prev.inMilliseconds,
            'toMs': position.inMilliseconds,
            'mediaDeltaMs': mediaDelta,
            'wallMs': wallMs,
          });
        }
      }
      _lastLoggedPosition = position;
      _lastPositionAt = now;
      setState(() => _position = position);
    });
    _completeSub = _player.onPlayerComplete.listen((_) async {
      if (!mounted) return;
      final wasPlaying = _playing;
      _voiceLog('complete', {'wasPlaying': wasPlaying});
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
      if (wasPlaying) {
        unawaited(VoicePlaybackProximityRoute.instance.onNotPlaying());
      }
      final id = _attachmentId;
      if (id != null && id > 0) {
        await ChatVoicePlaybackCoordinator.instance.notifyCompleted(id);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _voiceLog('lifecycle', {'state': state.name});
  }

  void _hookVolumeKeys(bool enable) {
    if (enable == _keyboardHooked) return;
    _keyboard ??= HardwareKeyboard.instance;
    if (enable) {
      _keyboard!.addHandler(_onKeyEvent);
      _keyboardHooked = true;
    } else {
      _keyboard!.removeHandler(_onKeyEvent);
      _keyboardHooked = false;
    }
  }

  bool _onKeyEvent(KeyEvent event) {
    // Log only while this bubble is playing — cheek may hit volume/power.
    if (!_playing) return false;
    if (event is! KeyDownEvent && event is! KeyUpEvent) return false;
    final key = event.logicalKey;
    final isVol = key == LogicalKeyboardKey.audioVolumeUp ||
        key == LogicalKeyboardKey.audioVolumeDown ||
        key == LogicalKeyboardKey.audioVolumeMute ||
        key == LogicalKeyboardKey.power ||
        key == LogicalKeyboardKey.headsetHook ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.mediaStop;
    if (!isVol) return false;
    _voiceLog('key', {
      'type': event.runtimeType.toString(),
      'key': key.keyLabel.isNotEmpty ? key.keyLabel : key.debugName,
      'keyId': key.keyId,
    });
    return false;
  }

  @override
  void didUpdateWidget(covariant ChatVoiceMessagePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = chatAsInt(oldWidget.attachment['id']);
    final newId = _attachmentId;
    if (oldId == newId) return;
    if (oldId != null && oldId > 0) {
      ChatVoicePlaybackCoordinator.instance.unregister(oldId, _handle);
    }
    if (newId != null && newId > 0) {
      ChatVoicePlaybackCoordinator.instance.register(newId, _handle);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hookVolumeKeys(false);
    final id = _attachmentId;
    if (id != null && id > 0) {
      ChatVoicePlaybackCoordinator.instance.unregister(id, _handle);
    }
    VoicePlaybackProximityRoute.instance.detachRouteRestart(_routeRestartToken);
    if (_playing) {
      _voiceLog('dispose_while_playing');
      unawaited(VoicePlaybackProximityRoute.instance.onNotPlaying());
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
    _voiceLog('pause_if_playing', {'why': 'coordinator'});
    await _player.pause();
  }

  Future<void> _applyRate(double rate) async {
    _rate = rate;
    _voiceLog('rate', {'rate': rate});
    try {
      await _player.setPlaybackRate(rate);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _cycleSpeed() {
    _voiceLog('ui_speed_tap');
    final next = ChatVoicePlaybackCoordinator.instance.cyclePlaybackRate();
    unawaited(_applyRate(next));
  }

  int _lastVoiceEnsureEpoch = -1;

  void _scheduleAutoDownload({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isTdlibVoice) {
        final fileId = _tdlibFileId;
        if (fileId == null || fileId <= 0) return;
        if (galleryLocalDevicePath(widget.attachment).isNotEmpty) return;
        final svc = ref.read(telegramTdlibServiceProvider);
        final cached = svc.cachedFilePath(fileId);
        if (cached != null && cached.isNotEmpty) return;
        // R70: after mtproto-up clears give-ups, retry once per epoch so a
        // voice that failed while !Ready can load without a second tap.
        final epoch = svc.mediaReadyEpoch;
        if (!force && epoch == _lastVoiceEnsureEpoch) return;
        _lastVoiceEnsureEpoch = epoch;
        unawaited(() async {
          final path = await svc.ensureFileLocal(
            fileId,
            priority: TelegramTdlibService.prioOpenChat,
            reason: 'voice:$fileId',
            waitFor: const Duration(seconds: 120),
          );
          if (!mounted) return;
          if (path != null && path.isNotEmpty) setState(() {});
        }());
        return;
      }
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

  Future<String?> _ensureTdlibLocal() async {
    final fileId = _tdlibFileId;
    if (fileId == null || fileId <= 0) return null;
    final svc = ref.read(telegramTdlibServiceProvider);
    await svc.preemptForUserTap(
      fileId: fileId,
      chatId: widget.threadId,
      reason: 'tap:voice:$fileId',
    );
    return svc.ensureFileLocal(
      fileId,
      priority: TelegramTdlibService.prioFocused,
      reason: 'tap:voice:$fileId',
      waitFor: const Duration(minutes: 10),
    );
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
    if (_preparing) {
      _voiceLog('toggle_busy', {'fromAutoplay': fromAutoplay});
      return;
    }
    if (_playing) {
      _voiceLog('ui_pause', {'fromAutoplay': fromAutoplay});
      await _player.pause();
      return;
    }

    _voiceLog('ui_play', {'fromAutoplay': fromAutoplay});
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

      var localPath = galleryLocalDevicePath(widget.attachment);
      if (localPath.isEmpty && _isTdlibVoice) {
        localPath = await _ensureTdlibLocal() ?? '';
      }
      if (localPath.isNotEmpty && localDeviceFileExists(localPath)) {
        _voiceLog('play_source', {'src': 'file', 'pathTail': _pathTail(localPath)});
        final src = DeviceFileSource(localPath, mimeType: mime);
        _activeSource = src;
        await _player.play(src);
        return;
      }

      final localBytes = widget.attachment['local_bytes'];
      if (localBytes is Uint8List && localBytes.isNotEmpty) {
        _voiceLog('play_source', {'src': 'bytes', 'len': localBytes.length});
        final src = BytesSource(localBytes, mimeType: mime);
        _activeSource = src;
        await _player.play(src);
        return;
      }

      if (_isTdlibVoice) {
        // TDLib path failed — do not hit FC /attachments HTTP (404 forever).
        _voiceLog('play_abort', {'why': 'tdlib-no-local'});
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
        if (bytes == null || bytes.isEmpty) {
          _voiceLog('play_abort', {'why': 'download-empty'});
          return;
        }
        _voiceLog('play_source', {'src': 'download', 'len': bytes.length});
        final src = BytesSource(bytes, mimeType: mime);
        _activeSource = src;
        await _player.play(src);
        return;
      }

      final repo = ref.read(familychatRepositoryProvider);
      final url = chatAttachmentImageUrl(
        repo: repo,
        threadId: widget.threadId,
        attachment: widget.attachment,
      );
      if (url.isNotEmpty) {
        _voiceLog('play_source', {'src': 'url'});
        final src = UrlSource(url, mimeType: mime);
        _activeSource = src;
        await _player.play(src);
      } else {
        _voiceLog('play_abort', {'why': 'no-url'});
      }
    } catch (e, st) {
      _voiceLog('play_fail', {'err': '$e'});
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

  static String _pathTail(String path) {
    final i = path.lastIndexOf('/');
    final j = path.lastIndexOf('\\');
    final cut = i > j ? i : j;
    return cut >= 0 ? path.substring(cut + 1) : path;
  }

  /// Scrapbook ставит global AudioContext в sonification/ambient — голос молчит.
  /// Opens the speaker/media pipeline before first play (TG default).
  Future<void> _ensureMediaAudioContext() async {
    await VoicePlaybackProximityRoute.prepareForPlayback();
  }

  /// TG `startAudioAgain`: reopen the same source after MUSIC↔VOICE_CALL flip.
  ///
  /// Must call [AudioPlayer.setAudioContext] on **this** player — global alone
  /// leaves the WrappedPlayer on USAGE_MEDIA / speaker.
  Future<void> _restartForAudioRoute({required bool earpiece}) async {
    final src = _activeSource;
    if (src == null) {
      _voiceLog('route_restart_skip', {'why': 'no-source', 'earpiece': earpiece});
      return;
    }
    if (!_playing && !_preparing) {
      _voiceLog('route_restart_skip', {'why': 'not-playing', 'earpiece': earpiece});
      return;
    }
    final pos = _position;
    final ctx = VoicePlaybackProximityRoute.contextFor(earpiece: earpiece);
    _voiceLog('route_restart', {
      'earpiece': earpiece,
      'posMs': pos.inMilliseconds,
    });
    _routeRestarting = true;
    try {
      await _player.setAudioContext(ctx);
      _voiceLog('player_audio_context', {
        'earpiece': earpiece,
        'kind': earpiece ? 'earpiece' : 'speaker',
      });
      await _player.stop();
      await _player.setPlaybackRate(_rate);
      await _player.play(src);
      if (pos > Duration.zero) {
        try {
          await _player.seek(pos);
        } catch (_) {}
      }
      VoicePlaybackProximityRoute.instance.attachRouteRestart(
        _routeRestartToken,
        _restartForAudioRoute,
      );
    } catch (e) {
      _voiceLog('route_restart_fail', {'err': '$e', 'earpiece': earpiece});
    } finally {
      _routeRestarting = false;
    }
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
                  _playing ? LucideIcons.pause : LucideIcons.play,
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

    // R70: re-ensure after plane restore (mediaReadyEpoch bump clears give-ups).
    if (_isTdlibVoice &&
        galleryLocalDevicePath(widget.attachment).isEmpty) {
      final epoch = ref.watch(
        telegramTdlibServiceProvider.select((s) => s.mediaReadyEpoch),
      );
      if (epoch != _lastVoiceEnsureEpoch) {
        _scheduleAutoDownload();
      }
    }

    final transcript = widget.transcript?.trim();
    final hasTranscript =
        transcript != null && transcript.isNotEmpty && widget.canToggleTranscript;
    final preferText = ref.watch(voiceMessagePreferTextProvider);
    // Max: voice stays; transcript opens under the player (not a replace).
    final showTranscriptBelow = hasTranscript && preferText;
    final canRequest = !hasTranscript &&
        widget.onRequestTranscript != null &&
        !widget.transcriptBusy;
    final showTranscriptChip =
        hasTranscript || canRequest || widget.transcriptBusy;

    final totalMs = _total.inMilliseconds > 0
        ? _total.inMilliseconds
        : (widget.durationMs ?? 0);
    final progress = totalMs > 0
        ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final label = _playing || _position.inMilliseconds > 0
        ? formatVoiceDuration(_position.inMilliseconds)
        : formatVoiceDuration(totalMs);

    final chipFg = widget.isMine ? Colors.white : accent;
    final chipBg = widget.isMine
        ? Colors.white.withValues(alpha: 0.20)
        : accent.withValues(alpha: 0.12);
    // Active →T when transcript is open (Max teal/filled look).
    final transcriptChipBg = showTranscriptBelow
        ? (widget.isMine
            ? Colors.white.withValues(alpha: 0.32)
            : accent)
        : chipBg;
    final transcriptChipFg = showTranscriptBelow
        ? (widget.isMine ? Colors.white : onAccent)
        : chipFg;

    Widget speedChip = _MaxVoiceChip(
      background: chipBg,
      foreground: chipFg,
      tooltip: 'Скорость',
      onTap: _cycleSpeed,
      child: Text(_maxSpeedLabel(ChatVoicePlaybackCoordinator.instance.playbackRate)),
    );

    Widget? transcriptChip;
    if (hasTranscript) {
      transcriptChip = _MaxVoiceChip(
        background: transcriptChipBg,
        foreground: transcriptChipFg,
        tooltip: showTranscriptBelow ? 'Скрыть текст' : 'Показать текст',
        onTap: () {
          ref.read(voiceMessagePreferTextProvider.notifier).toggle();
        },
        child: _MaxArrowT(color: transcriptChipFg),
      );
    } else if (widget.transcriptBusy) {
      transcriptChip = _MaxVoiceChip(
        background: chipBg,
        foreground: chipFg,
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: chipFg,
          ),
        ),
      );
    } else if (canRequest) {
      transcriptChip = _MaxVoiceChip(
        background: chipBg,
        foreground: chipFg,
        tooltip: 'Получить текст',
        onTap: widget.onRequestTranscript,
        child: _MaxArrowT(color: chipFg),
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

    final waveInactive = widget.isMine
        ? Colors.white.withValues(alpha: 0.35)
        : metaColor.withValues(alpha: 0.45);
    final waveActive = widget.isMine ? Colors.white : accent;
    final durationColor = widget.isMine
        ? Colors.white.withValues(alpha: 0.85)
        : accent;

    final bubbleMax = widget.maxWidth ?? 280;
    // Compact voice ≈ Max short bubble; with transcript → full text width.
    final maxW = showTranscriptBelow ? bubbleMax : math.min(280.0, bubbleMax);
    final minW = showTranscriptBelow ? math.min(220.0, maxW) : 200.0;

    final player = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 28,
                      child: _VoiceWaveformBar(
                        progress: progress,
                        seed: _attachmentId ?? widget.threadId,
                        activeColor: waveActive,
                        inactiveColor: waveInactive,
                        onSeekFraction: totalMs <= 0
                            ? null
                            : (fraction) async {
                                final ms = (fraction * totalMs).round();
                                setState(
                                  () => _position =
                                      Duration(milliseconds: ms),
                                );
                                _voiceLog('ui_seek', {
                                  'toMs': ms,
                                  'fromMs': _position.inMilliseconds,
                                });
                                await _player
                                    .seek(Duration(milliseconds: ms));
                              },
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  speedChip,
                  if (showTranscriptChip && transcriptChip != null) ...[
                    const SizedBox(width: 4),
                    transcriptChip,
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: durationColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minW, maxWidth: maxW),
      child: showTranscriptBelow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                player,
                const SizedBox(height: 8),
                Text(
                  transcript!,
                  style: TextStyle(
                    color: textColor,
                    height: 1.35,
                    fontSize: 15,
                  ),
                ),
              ],
            )
          : player,
    );
  }

  static String _maxSpeedLabel(double rate) {
    if (rate == 1.0) return '1x';
    if (rate == 1.25) return '1.25x';
    if (rate == 1.5) return '1.5x';
    if (rate == 2.0) return '2x';
    if (rate == 3.0) return '3x';
    final s = rate.toStringAsFixed(2);
    return '${s.replaceFirst(RegExp(r'\.?0+$'), '')}x';
  }
}

/// Max-style chip: soft tinted rounded square (speed / →T).
class _MaxVoiceChip extends StatelessWidget {
  const _MaxVoiceChip({
    required this.background,
    required this.foreground,
    required this.child,
    this.onTap,
    this.tooltip,
  });

  final Color background;
  final Color foreground;
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      color: background,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            child: Center(
              child: DefaultTextStyle(
                style: TextStyle(
                  color: foreground,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
                child: IconTheme(
                  data: IconThemeData(color: foreground, size: 15),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final tip = tooltip?.trim() ?? '';
    if (tip.isEmpty) return chip;
    return Tooltip(message: tip, child: chip);
  }
}

class _MaxArrowT extends StatelessWidget {
  const _MaxArrowT({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.arrow_forward_rounded, size: 13, color: color),
        Text(
          'T',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ],
    );
  }
}

class _VoiceWaveformBar extends StatelessWidget {
  const _VoiceWaveformBar({
    required this.progress,
    required this.seed,
    required this.activeColor,
    required this.inactiveColor,
    this.onSeekFraction,
  });

  final double progress;
  final int seed;
  final Color activeColor;
  final Color inactiveColor;
  final Future<void> Function(double fraction)? onSeekFraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onSeekFraction == null
              ? null
              : (details) {
                  final w = constraints.maxWidth;
                  if (w <= 0) return;
                  final f = (details.localPosition.dx / w).clamp(0.0, 1.0);
                  unawaited(onSeekFraction!(f));
                },
          onHorizontalDragUpdate: onSeekFraction == null
              ? null
              : (details) {
                  final w = constraints.maxWidth;
                  if (w <= 0) return;
                  final f = (details.localPosition.dx / w).clamp(0.0, 1.0);
                  unawaited(onSeekFraction!(f));
                },
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _VoiceWaveformPainter(
              progress: progress,
              seed: seed,
              activeColor: activeColor,
              inactiveColor: inactiveColor,
            ),
          ),
        );
      },
    );
  }
}

class _VoiceWaveformPainter extends CustomPainter {
  _VoiceWaveformPainter({
    required this.progress,
    required this.seed,
    required this.activeColor,
    required this.inactiveColor,
  });

  final double progress;
  final int seed;
  final Color activeColor;
  final Color inactiveColor;

  static const _barCount = 36;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed == 0 ? 7 : seed);
    final heights = List<double>.generate(_barCount, (_) {
      // Prefer mid-height bars with some peaks — Max-like voice shape.
      final base = 0.28 + rnd.nextDouble() * 0.55;
      final peak = rnd.nextDouble() < 0.18 ? 0.2 + rnd.nextDouble() * 0.25 : 0;
      return (base + peak).clamp(0.22, 1.0);
    });

    final gap = size.width / (_barCount * 2.2);
    final barW = math.max(2.0, (size.width - gap * (_barCount + 1)) / _barCount);
    final paint = Paint()..style = PaintingStyle.fill;
    final playedUntil = (progress.clamp(0.0, 1.0) * _barCount);

    for (var i = 0; i < _barCount; i++) {
      final h = heights[i] * size.height;
      final x = gap + i * (barW + gap);
      final y = (size.height - h) / 2;
      paint.color = i + 1 <= playedUntil ? activeColor : inactiveColor;
      final r = Radius.circular(barW / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, barW, h), r),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceWaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.seed != seed ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}
