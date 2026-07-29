import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/media/gallery_media_utils.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../../core/widgets/gallery_video_player.dart';

/// Полноэкранный диафильм: автосмена фото с эффектами, пауза и скорость.
class PhotoSlideshowScreen extends StatefulWidget {
  const PhotoSlideshowScreen({
    super.key,
    required this.photos,
    this.initialIndex = 0,
  });

  final List<Map<String, dynamic>> photos;
  final int initialIndex;

  /// Открыть диафильм с [startIndex] до конца списка.
  static Future<void> open(
    BuildContext context, {
    required List<Map<String, dynamic>> photos,
    int startIndex = 0,
  }) {
    if (photos.length < 2) return Future<void>.value();
    final start = startIndex.clamp(0, photos.length - 1);
    final slice = photos.sublist(start);
    if (slice.length < 2) return Future<void>.value();
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => PhotoSlideshowScreen(photos: slice),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(opacity: anim, child: child);
        },
      ),
    );
  }

  @override
  State<PhotoSlideshowScreen> createState() => _PhotoSlideshowScreenState();
}

class _PhotoSlideshowScreenState extends State<PhotoSlideshowScreen> {
  static const _speeds = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 14),
  ];

  late int _index;
  late int _speedIndex;
  bool _paused = false;
  int _effectKind = 0;
  Timer? _timer;
  double _dragDx = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _speedIndex = 1; // 5 секунд по умолчанию
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Duration get _interval => _speeds[_speedIndex];

  Map<String, dynamic> get _photo => widget.photos[_index];

  void _restartTimer() {
    _timer?.cancel();
    if (_paused) return;
    _timer = Timer(_interval, _onTick);
  }

  void _onTick() {
    if (!mounted || _paused) return;
    if (_index >= widget.photos.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _effectKind = (_effectKind + 1) % 4;
      _index += 1;
      _dragDx = 0;
    });
    _restartTimer();
  }

  void _goNext({bool manual = false}) {
    if (_index >= widget.photos.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      if (!manual) _effectKind = (_effectKind + 1) % 4;
      else _effectKind = 1; // slide left-to-right feel
      _index += 1;
      _dragDx = 0;
    });
    _restartTimer();
  }

  void _goPrev() {
    if (_index <= 0) return;
    setState(() {
      _effectKind = 3;
      _index -= 1;
      _dragDx = 0;
    });
    _restartTimer();
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (_paused) {
      _timer?.cancel();
    } else {
      _restartTimer();
    }
  }

  void _cycleSpeed() {
    setState(() => _speedIndex = (_speedIndex + 1) % _speeds.length);
    _restartTimer();
  }

  Widget _transition(Widget child, Animation<double> anim) {
    switch (_effectKind % 4) {
      case 0:
        return FadeTransition(opacity: anim, child: child);
      case 1:
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.18, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: FadeTransition(opacity: anim, child: child),
        );
      case 2:
        return ScaleTransition(
          scale: Tween<double>(begin: 1.08, end: 1.0).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          ),
          child: FadeTransition(opacity: anim, child: child),
        );
      default:
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-0.18, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: FadeTransition(opacity: anim, child: child),
        );
    }
  }

  Widget _buildMedia(Map<String, dynamic> photo) {
    if (isVideoAttachment(photo)) {
      return GalleryVideoPlayer(
        url: galleryAttachmentUrl(photo),
        fit: BoxFit.contain,
        autoplay: true,
        showControls: false,
      );
    }
    final local = photo['local_bytes'];
    if (local is Uint8List && local.isNotEmpty) {
      return Image.memory(local, fit: BoxFit.contain, gaplessPlayback: true);
    }
    return FamilyPublicImage(
      url: galleryAttachmentUrl(photo),
      fit: BoxFit.contain,
      placeholder: const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      ),
      error: const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _interval.inSeconds;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: _togglePause,
            onHorizontalDragUpdate: (d) {
              setState(() => _dragDx += d.delta.dx);
            },
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -300 || _dragDx < -80) {
                _goNext(manual: true);
              } else if (v > 300 || _dragDx > 80) {
                _goPrev();
              } else {
                setState(() => _dragDx = 0);
              }
            },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 700),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: _transition,
              child: KeyedSubtree(
                key: ValueKey<int>(_index),
                child: Center(child: _buildMedia(_photo)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  const Spacer(),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        '${_index + 1} / ${widget.photos.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_paused)
            const IgnorePointer(
              child: Center(
                child: Icon(
                  Icons.pause_circle_filled,
                  color: Colors.white70,
                  size: 72,
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _paused ? 'Продолжить' : 'Пауза',
                          onPressed: _togglePause,
                          icon: Icon(
                            _paused ? Icons.play_arrow : Icons.pause,
                            color: Colors.white,
                          ),
                        ),
                        TextButton(
                          onPressed: _cycleSpeed,
                          child: Text(
                            '$seconds сек',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
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
      ),
    );
  }
}