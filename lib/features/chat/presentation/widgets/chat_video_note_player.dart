import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/local_device_file.dart';
import '../../../../core/providers/app_providers.dart';
import 'chat_network_image.dart';

/// Видео-кружок в чате: круг, тап — увеличение и проигрывание с кольцом прогресса.
class ChatVideoNotePlayer extends ConsumerStatefulWidget {
  const ChatVideoNotePlayer({
    super.key,
    required this.threadId,
    required this.attachment,
    this.durationMs,
    this.idleSize = 196,
    this.expandedSize,
    this.interactive = true,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final int? durationMs;
  final double idleSize;
  /// Если null — почти на всю ширину окна чата.
  final double? expandedSize;
  final bool interactive;

  static double defaultExpandedSize(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return (width - 20).clamp(280.0, width);
  }

  @override
  ConsumerState<ChatVideoNotePlayer> createState() =>
      _ChatVideoNotePlayerState();
}

class _ChatVideoNotePlayerState extends ConsumerState<ChatVideoNotePlayer>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  Object? _error;
  bool _expanded = false;
  bool _ready = false;
  bool _collapsing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final ms = widget.durationMs;
    if (ms != null && ms > 0) {
      _duration = Duration(milliseconds: ms);
    }
    _init();
  }

  @override
  void didUpdateWidget(covariant ChatVideoNotePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment['id'] != widget.attachment['id'] ||
        oldWidget.attachment['file_url'] != widget.attachment['file_url'] ||
        oldWidget.attachment['local_device_path'] !=
            widget.attachment['local_device_path']) {
      _disposeController();
      _ready = false;
      _expanded = false;
      _init();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.resumed) {
      if (_expanded) {
        c.play();
      } else if (!c.value.isPlaying) {
        c.play();
      }
    } else {
      c.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _controller = null;
  }

  Future<void> _init() async {
    final localPath = galleryLocalDevicePath(widget.attachment);
    VideoPlayerController? controller;
    if (localPath.isNotEmpty) {
      controller = localDeviceVideoController(localPath);
    }
    if (controller == null) {
      final url = chatAttachmentImageUrl(
        repo: ref.read(familychatRepositoryProvider),
        threadId: widget.threadId,
        attachment: widget.attachment,
      );
      if (url.isEmpty) {
        if (mounted) setState(() => _error = StateError('Нет видео'));
        return;
      }
      controller = VideoPlayerController.networkUrl(Uri.parse(url));
    }
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      final d = controller.value.duration;
      if (d > Duration.zero) _duration = d;
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      controller.addListener(_onTick);
      if (mounted) {
        setState(() {
          _ready = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _onTick() {
    final c = _controller;
    if (!mounted || c == null || !c.value.isInitialized) return;
    final pos = c.value.position;
    final dur = c.value.duration;
    setState(() {
      _position = pos;
      if (dur > Duration.zero) _duration = dur;
    });
    if (!_expanded || _collapsing) return;
    if (dur <= Duration.zero) return;
    final atEnd = pos >= dur - const Duration(milliseconds: 200);
    if (atEnd && !c.value.isPlaying) {
      _collapsing = true;
      unawaited(_collapseToIdle().whenComplete(() {
        _collapsing = false;
      }));
    }
  }

  Future<void> _collapseToIdle() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    await c.setVolume(0);
    await c.setLooping(true);
    await c.seekTo(Duration.zero);
    await c.play();
    if (mounted) {
      setState(() {
        _expanded = false;
        _position = Duration.zero;
      });
    }
  }

  Future<void> _onTap() async {
    if (!widget.interactive) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (_expanded) {
      if (c.value.isPlaying) {
        await c.pause();
        if (mounted) setState(() {});
      } else {
        final dur = c.value.duration;
        if (dur > Duration.zero &&
            c.value.position >= dur - const Duration(milliseconds: 120)) {
          await c.seekTo(Duration.zero);
        }
        await c.play();
        if (mounted) setState(() {});
      }
      return;
    }

    setState(() => _expanded = true);
    await c.setLooping(false);
    await c.setVolume(1);
    await c.seekTo(Duration.zero);
    await c.play();
    if (mounted) setState(() {});
  }

  double get _progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final size = _expanded
        ? (widget.expandedSize ??
            ChatVideoNotePlayer.defaultExpandedSize(context))
        : widget.idleSize;
    final localBytes = widget.attachment['local_bytes'];
    Widget? placeholder;
    if (isSafeUiPreviewBytes(localBytes)) {
      placeholder = Image.memory(
        localBytes as Uint8List,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }

    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ClipOval(
              child: SizedBox(
                width: size,
                height: size,
                child: _buildVideo(placeholder),
              ),
            ),
            if (_expanded)
              IgnorePointer(
                child: CustomPaint(
                  size: Size(size, size),
                  painter: _VideoNoteProgressPainter(
                    progress: _progress,
                    trackColor: Colors.white.withValues(alpha: 0.28),
                    progressColor: Colors.white,
                    strokeWidth: 3.2,
                  ),
                ),
              )
            else
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.35),
                      width: 1.5,
                    ),
                  ),
                  child: SizedBox(width: size, height: size),
                ),
              ),
            if (_ready && !_expanded)
              IgnorePointer(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            if (_expanded && _ready && !(_controller?.value.isPlaying ?? false))
              IgnorePointer(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo(Widget? placeholder) {
    if (_error != null) {
      return ColoredBox(
        color: Colors.black26,
        child: Center(
          child: placeholder ??
              const Icon(Icons.videocam_off_outlined, color: Colors.white54),
        ),
      );
    }
    final c = _controller;
    if (!_ready || c == null || !c.value.isInitialized) {
      return ColoredBox(
        color: Colors.black26,
        child: Center(
          child: placeholder ??
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              ),
        ),
      );
    }

    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}

class _VideoNoteProgressPainter extends CustomPainter {
  _VideoNoteProgressPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, track);
    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _VideoNoteProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
