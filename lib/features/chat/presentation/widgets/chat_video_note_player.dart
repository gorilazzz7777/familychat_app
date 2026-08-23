import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/gallery_video_thumbnail.dart';
import '../../../../core/media/local_device_file.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/widgets/family_public_image.dart';
import 'chat_network_image.dart';

/// Видео-кружок в чате: превью в списке, проигрывание только по тапу.
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
  bool _initializing = false;
  bool _collapsing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Uint8List? _thumbBytes;
  String? _thumbPath;
  String? _thumbUrl;
  int _thumbGen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final ms = widget.durationMs;
    if (ms != null && ms > 0) {
      _duration = Duration(milliseconds: ms);
    }
    unawaited(_loadIdleThumb());
  }

  @override
  void didUpdateWidget(covariant ChatVideoNotePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment['id'] != widget.attachment['id'] ||
        oldWidget.attachment['file_url'] != widget.attachment['file_url'] ||
        oldWidget.attachment['local_device_path'] !=
            widget.attachment['local_device_path'] ||
        oldWidget.attachment['thumbnail_url'] !=
            widget.attachment['thumbnail_url'] ||
        oldWidget.attachment['local_bytes'] !=
            widget.attachment['local_bytes']) {
      _resetPlayback();
      unawaited(_loadIdleThumb());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized || !_expanded) return;
    if (state == AppLifecycleState.resumed) {
      if (!c.value.isPlaying) unawaited(c.play());
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

  void _resetPlayback() {
    _disposeController();
    _ready = false;
    _expanded = false;
    _initializing = false;
    _collapsing = false;
    _position = Duration.zero;
    _error = null;
    _thumbBytes = null;
    _thumbPath = null;
    _thumbUrl = null;
    final ms = widget.durationMs;
    if (ms != null && ms > 0) {
      _duration = Duration(milliseconds: ms);
    }
  }

  void _disposeController() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _controller = null;
  }

  Future<void> _loadIdleThumb() async {
    final att = widget.attachment;
    final gen = ++_thumbGen;

    final localPreview = safeUiPreviewBytes(
      thumbnailBytes: att['thumbnail_bytes'] is Uint8List
          ? att['thumbnail_bytes'] as Uint8List
          : null,
      bytes: att['local_bytes'] is Uint8List
          ? att['local_bytes'] as Uint8List
          : null,
      kind: 'image',
    );
    if (localPreview != null) {
      if (!mounted || gen != _thumbGen) return;
      setState(() {
        _thumbBytes = localPreview;
        _thumbPath = null;
        _thumbUrl = null;
      });
      return;
    }

    final thumbUrl = att['thumbnail_url']?.toString().trim() ?? '';
    if (thumbUrl.isNotEmpty) {
      if (!mounted || gen != _thumbGen) return;
      setState(() {
        _thumbBytes = null;
        _thumbPath = null;
        _thumbUrl = thumbUrl;
      });
      return;
    }

    if (kIsWeb) return;

    final forThumb = Map<String, dynamic>.from(att);
    if (forThumb['kind']?.toString() != 'video') {
      forThumb['kind'] = 'video';
    }
    final path = await GalleryVideoThumbnail.ensureForAttachment(
      forThumb,
      maxWidth: 256,
      timeMs: 0,
    );
    if (!mounted || gen != _thumbGen) return;
    if (path == null || path.isEmpty) return;
    setState(() {
      _thumbBytes = null;
      _thumbUrl = null;
      _thumbPath = path;
    });
  }

  Future<void> _ensureExpandedPlayback() async {
    if (_initializing) return;
    final existing = _controller;
    if (existing != null && existing.value.isInitialized) {
      setState(() => _expanded = true);
      await existing.setLooping(false);
      await existing.setVolume(1);
      await existing.seekTo(Duration.zero);
      await existing.play();
      if (mounted) setState(() {});
      return;
    }

    setState(() {
      _expanded = true;
      _initializing = true;
      _error = null;
    });

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
        if (mounted) {
          setState(() {
            _initializing = false;
            _expanded = false;
            _error = StateError('Нет видео');
          });
        }
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
      await controller.setLooping(false);
      await controller.setVolume(1);
      controller.addListener(_onTick);
      await controller.play();
      if (mounted) {
        setState(() {
          _ready = true;
          _initializing = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _expanded = false;
          _error = e;
        });
      }
      _disposeController();
      _ready = false;
    }
  }

  void _onTick() {
    final c = _controller;
    if (!mounted || c == null || !c.value.isInitialized || !_expanded) return;
    final pos = c.value.position;
    final dur = c.value.duration;
    setState(() {
      _position = pos;
      if (dur > Duration.zero) _duration = dur;
    });
    if (_collapsing) return;
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
    _disposeController();
    if (mounted) {
      setState(() {
        _expanded = false;
        _ready = false;
        _position = Duration.zero;
      });
    }
  }

  Future<void> _onTap() async {
    if (!widget.interactive) return;

    if (!_expanded) {
      await _ensureExpandedPlayback();
      return;
    }

    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (c.value.isPlaying) {
      await c.pause();
      if (mounted) setState(() {});
      return;
    }

    final dur = c.value.duration;
    if (dur > Duration.zero &&
        c.value.position >= dur - const Duration(milliseconds: 120)) {
      await c.seekTo(Duration.zero);
    }
    await c.play();
    if (mounted) setState(() {});
  }

  double get _progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Widget? _idlePlaceholder(BuildContext context) {
    final bytes = _thumbBytes;
    if (bytes != null && bytes.isNotEmpty) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final px = (widget.idleSize * dpr).round().clamp(64, 512);
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        cacheWidth: px,
        cacheHeight: px,
      );
    }
    final path = _thumbPath;
    if (path != null && path.isNotEmpty && localDeviceFileExists(path)) {
      return localDeviceFileImage(
        path: path,
        fit: BoxFit.cover,
      );
    }
    final url = _thumbUrl;
    if (url != null && url.isNotEmpty) {
      return FamilyPublicImage(
        url: url,
        fit: BoxFit.cover,
        error: const SizedBox.shrink(),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final size = _expanded
        ? (widget.expandedSize ??
            ChatVideoNotePlayer.defaultExpandedSize(context))
        : widget.idleSize;
    final placeholder = _idlePlaceholder(context);
    final c = _controller;
    final showPlayer =
        _expanded && !_initializing && c != null && c.value.isInitialized;

    return RepaintBoundary(
      child: GestureDetector(
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          clipBehavior: (showPlayer || placeholder != null)
              ? Clip.antiAlias
              : Clip.none,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black26,
            border: _expanded
                ? null
                : Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 1.5,
                  ),
          ),
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              if (showPlayer)
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: c.value.size.width,
                    height: c.value.size.height,
                    child: VideoPlayer(c),
                  ),
                )
              else if (placeholder != null)
                placeholder
              else
                Center(
                  child: _error != null && !_expanded
                      ? const Icon(
                          Icons.videocam_off_outlined,
                          color: Colors.white54,
                        )
                      : (_initializing
                          ? const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            )
                          : const Icon(
                              Icons.videocam_outlined,
                              color: Colors.white54,
                              size: 36,
                            )),
                ),
              if (_expanded)
                IgnorePointer(
                  child: CustomPaint(
                    painter: _VideoNoteProgressPainter(
                      progress: _progress,
                      trackColor: Colors.white.withValues(alpha: 0.28),
                      progressColor: Colors.white,
                      strokeWidth: 3.2,
                    ),
                  ),
                ),
              if (!_expanded ||
                  (_expanded &&
                      _ready &&
                      !(_controller?.value.isPlaying ?? false)))
                IgnorePointer(
                  child: Center(
                    child: Container(
                      width: _expanded ? 48 : 44,
                      height: _expanded ? 48 : 44,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _initializing
                            ? Icons.hourglass_top_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: _expanded ? 32 : 30,
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
