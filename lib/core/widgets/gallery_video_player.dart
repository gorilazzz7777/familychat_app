import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class GalleryVideoPlayer extends StatefulWidget {
  const GalleryVideoPlayer({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
    this.autoplay = false,
    this.showControls = true,
  });

  final String url;
  final BoxFit fit;
  final bool autoplay;
  final bool showControls;

  @override
  State<GalleryVideoPlayer> createState() => _GalleryVideoPlayerState();
}

class _GalleryVideoPlayerState extends State<GalleryVideoPlayer> {
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant GalleryVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _disposeController();
      _init();
    }
  }

  Future<void> _init() async {
    final url = widget.url.trim();
    if (url.isEmpty) {
      setState(() => _error = StateError('Пустой URL видео'));
      return;
    }
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      if (widget.autoplay) {
        await controller.play();
      }
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  void _disposeController() {
    _controller?.dispose();
    _controller = null;
    _error = null;
  }

  @override
  void dispose() {
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
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(
        child: Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 48),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    Widget video = FittedBox(
      fit: widget.fit,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );

    if (!widget.showControls) {
      return video;
    }

    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        video,
        if (!controller.value.isPlaying)
          IconButton(
            iconSize: 64,
            color: Colors.white.withValues(alpha: 0.92),
            onPressed: _togglePlayback,
            icon: const Icon(Icons.play_circle_fill),
          ),
        if (controller.value.isPlaying)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _togglePlayback,
            child: const SizedBox.expand(),
          ),
      ],
    );
  }
}
