import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:video_player/video_player.dart';

import '../media/local_device_file.dart';
import '../settings/app_screen_keep_on.dart';

/// Compact play affordance — same look as multi-video album cells.
class GalleryVideoPlayBadge extends StatelessWidget {
  const GalleryVideoPlayBadge({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0x73000000),
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(11, 9, 9, 9),
        child: Icon(
          LucideIcons.play,
          color: Colors.white,
          size: size,
        ),
      ),
    );
  }
}

String formatGalleryVideoClock(Duration d) {
  final total = d.inMilliseconds < 0 ? 0 : d.inMilliseconds;
  final s = (total / 1000).floor();
  final m = s ~/ 60;
  final rem = s % 60;
  if (m >= 60) {
    final h = m ~/ 60;
    final mm = m % 60;
    return '$h:${mm.toString().padLeft(2, '0')}:${rem.toString().padLeft(2, '0')}';
  }
  return '$m:${rem.toString().padLeft(2, '0')}';
}

class GalleryVideoPlayer extends StatefulWidget {
  const GalleryVideoPlayer({
    super.key,
    required this.url,
    this.localPath,
    this.httpHeaders,
    this.fit = BoxFit.contain,
    this.autoplay = false,
    this.looping = false,
    this.muted = false,
    this.showControls = true,
    /// Bottom elapsed/total + seek bar (inline + fullscreen).
    this.showScrubber = false,
    /// Compact elapsed/total (top-left) + mute for inline chat playback.
    this.showMuteClock = false,
    this.placeholder,
    this.onResolvedSize,
    /// Fired once when playback actually starts (playing, not just initialized).
    this.onPlaybackStarted,
    /// Fired once when [initialize]/[play] fails.
    this.onError,
    /// Fired once when playback reaches the end (non-looping only).
    this.onEnded,
  });

  final String url;
  final String? localPath;
  final Map<String, String>? httpHeaders;
  final BoxFit fit;
  final bool autoplay;
  final bool looping;
  final bool muted;
  final bool showControls;
  final bool showScrubber;
  final bool showMuteClock;
  final Widget? placeholder;
  final ValueChanged<Size>? onResolvedSize;
  final VoidCallback? onPlaybackStarted;
  final ValueChanged<Object>? onError;
  final VoidCallback? onEnded;

  @override
  State<GalleryVideoPlayer> createState() => _GalleryVideoPlayerState();
}

class _GalleryVideoPlayerState extends State<GalleryVideoPlayer>
    with WidgetsBindingObserver {
  static int _keepOnSeq = 0;

  VideoPlayerController? _controller;
  Object? _error;
  bool _scrubbing = false;
  double _scrubValue = 0;
  late bool _muted;
  bool _endedNotified = false;
  bool _playbackStartedNotified = false;
  late final String _keepOnId = 'gallery_video_${++_keepOnSeq}';
  bool _keepOnHeld = false;

  @override
  void initState() {
    super.initState();
    _muted = widget.muted;
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.resumed) {
      if (widget.autoplay) {
        unawaited(controller.play());
      }
      _syncKeepOn();
    } else {
      unawaited(controller.pause());
      _releaseKeepOn();
    }
  }

  void _syncKeepOn() {
    final playing = _controller?.value.isInitialized == true &&
        (_controller?.value.isPlaying ?? false);
    if (playing) {
      if (_keepOnHeld) return;
      _keepOnHeld = true;
      unawaited(AppScreenKeepOn.acquire(_keepOnId));
    } else {
      _releaseKeepOn();
    }
  }

  void _releaseKeepOn() {
    if (!_keepOnHeld) return;
    _keepOnHeld = false;
    unawaited(AppScreenKeepOn.release(_keepOnId));
  }

  @override
  void didUpdateWidget(covariant GalleryVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.localPath != widget.localPath) {
      _disposeController();
      _muted = widget.muted;
      _init();
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (oldWidget.looping != widget.looping) {
      unawaited(controller.setLooping(widget.looping));
    }
    if (oldWidget.muted != widget.muted && widget.muted != _muted) {
      _muted = widget.muted;
      unawaited(controller.setVolume(_muted ? 0 : 1));
    }
    if (oldWidget.autoplay != widget.autoplay) {
      if (widget.autoplay) {
        unawaited(controller.play());
      } else {
        unawaited(controller.pause());
      }
      _syncKeepOn();
    }
  }

  Future<void> _init() async {
    final local = widget.localPath?.trim() ?? '';
    VideoPlayerController? controller;
    if (local.isNotEmpty) {
      controller = localDeviceVideoController(local);
    }
    if (controller == null) {
      final url = widget.url.trim();
      if (url.isEmpty) {
        final err = StateError('Пустой URL видео');
        if (mounted) setState(() => _error = err);
        widget.onError?.call(err);
        return;
      }
      final headers = widget.httpHeaders;
      controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: headers ?? const <String, String>{},
      );
    }
    _controller = controller;
    _playbackStartedNotified = false;
    try {
      await controller.initialize();
      if (!mounted) return;
      _endedNotified = false;
      await controller.setLooping(widget.looping);
      await controller.setVolume(_muted ? 0 : 1);
      if (widget.autoplay) {
        await controller.play();
      }
      // Always listen for play/pause so wakelock tracks playback even without UI.
      controller.addListener(_onTick);
      final size = controller.value.size;
      if (size.width > 0 && size.height > 0) {
        widget.onResolvedSize?.call(size);
      }
      _syncKeepOn();
      _maybeNotifyPlaybackStarted();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      widget.onError?.call(e);
    }
  }

  void _onTick() {
    if (!mounted) return;
    if (!_scrubbing) setState(() {});
    _syncKeepOn();
    _maybeNotifyPlaybackStarted();
    _maybeNotifyEnded();
  }

  void _maybeNotifyPlaybackStarted() {
    if (_playbackStartedNotified || widget.onPlaybackStarted == null) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final v = controller.value;
    if (!v.isPlaying) return;
    // Progressive/stream: wait until buffering clears or the first frame advances.
    if (v.isBuffering && v.position <= Duration.zero) return;
    _playbackStartedNotified = true;
    widget.onPlaybackStarted!();
  }

  void _maybeNotifyEnded() {
    if (widget.looping || widget.onEnded == null) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      _endedNotified = false;
      return;
    }
    if (!controller.value.isCompleted || _endedNotified) return;
    _endedNotified = true;
    widget.onEnded!();
  }

  void _disposeController() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _controller = null;
    _error = null;
    _playbackStartedNotified = false;
    _releaseKeepOn();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeController();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _syncKeepOn();
    if (mounted) setState(() {});
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = !_muted;
    _muted = next;
    await controller.setVolume(next ? 0 : 1);
    if (mounted) setState(() {});
  }

  Future<void> _seekFraction(double value) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final total = controller.value.duration.inMilliseconds;
    if (total <= 0) return;
    final ms = (value.clamp(0.0, 1.0) * total).round();
    await controller.seekTo(Duration(milliseconds: ms));
  }

  Widget _buildMuteClock(VideoPlayerController controller) {
    final total = controller.value.duration;
    final position = controller.value.position;
    final clock = DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Text(
          '${formatGalleryVideoClock(position)} / '
          '${formatGalleryVideoClock(total)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1.1,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
    // Scrubber already has mute — clock-only top-left.
    if (widget.showScrubber) {
      return Positioned(left: 6, top: 6, child: clock);
    }
    // Autoplay inline: elapsed/total top-left; mute top-right.
    return Positioned(
      left: 6,
      right: 6,
      top: 6,
      child: Row(
        children: [
          clock,
          const Spacer(),
          Material(
            color: Colors.black.withValues(alpha: 0.48),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => unawaited(_toggleMute()),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Icon(
                  _muted ? LucideIcons.volume_x : LucideIcons.volume_2,
                  color: Colors.white,
                  size: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScrubber(VideoPlayerController controller) {
    final total = controller.value.duration;
    final position = _scrubbing
        ? Duration(
            milliseconds: (_scrubValue * total.inMilliseconds)
                .round()
                .clamp(0, total.inMilliseconds),
          )
        : controller.value.position;
    final maxMs = total.inMilliseconds;
    final value = maxMs <= 0
        ? 0.0
        : (_scrubbing
            ? _scrubValue
            : (position.inMilliseconds / maxMs).clamp(0.0, 1.0));
    final showTransport = widget.showControls || widget.showScrubber;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (showTransport) ...[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(_togglePlayback()),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(2, 4, 8, 4),
                        child: Icon(
                          controller.value.isPlaying
                              ? LucideIcons.pause
                              : LucideIcons.play,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                  // Time lives top-left via [showMuteClock] on inline bubbles.
                  if (!widget.showMuteClock) ...[
                    Text(
                      formatGalleryVideoClock(position),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                    const Text(
                      ' / ',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      formatGalleryVideoClock(total),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        height: 1.1,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (showTransport)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(_toggleMute()),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 2, 4),
                        child: Icon(
                          _muted ? LucideIcons.volume_x : LucideIcons.volume_2,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                ),
                child: Slider(
                  value: value,
                  onChangeStart: (v) {
                    _scrubbing = true;
                    _scrubValue = v;
                  },
                  onChanged: (v) {
                    setState(() => _scrubValue = v);
                  },
                  onChangeEnd: (v) async {
                    _scrubValue = v;
                    await _seekFraction(v);
                    _scrubbing = false;
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return widget.placeholder ??
          const Center(
            child: Icon(LucideIcons.video_off, color: Colors.white54, size: 48),
          );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return widget.placeholder ??
          const Center(child: CircularProgressIndicator());
    }

    Widget video = FittedBox(
      fit: widget.fit,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );

    final showOverlay = widget.showControls ||
        widget.showScrubber ||
        widget.showMuteClock;
    if (!showOverlay) {
      return video;
    }

    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        video,
        if (widget.showControls && !controller.value.isPlaying)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_togglePlayback()),
            child: const ColoredBox(
              color: Color(0x22000000),
              child: Center(child: GalleryVideoPlayBadge()),
            ),
          )
        else if (widget.showControls || widget.showScrubber)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_togglePlayback()),
            child: const SizedBox.expand(),
          ),
        if (widget.showScrubber) _buildScrubber(controller),
        // Top-left clock even when scrubber is on (user inline play).
        if (widget.showMuteClock) _buildMuteClock(controller),
      ],
    );
  }
}
