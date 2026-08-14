import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/media/gallery_media_utils.dart';
import '../../../core/settings/app_screen_keep_on.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../../core/widgets/gallery_video_player.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';

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

class _PhotoSlideshowScreenState extends State<PhotoSlideshowScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _speeds = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 14),
  ];

  static const _effectCount = 7;

  late int _index;
  late int _speedIndex;
  bool _paused = false;
  int _effectKind = 0;
  Timer? _timer;
  double _dragDx = 0;

  late final AnimationController _transitionCtrl;
  int? _outgoingIndex;
  bool _outgoingOnTop = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _speedIndex = 1; // 5 секунд по умолчанию
    _transitionCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() {
            _outgoingIndex = null;
            _outgoingOnTop = false;
          });
        }
      });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(AppScreenKeepOn.acquire('slideshow'));
    _restartTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _transitionCtrl.dispose();
    unawaited(AppScreenKeepOn.release('slideshow'));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_paused) unawaited(AppScreenKeepOn.acquire('slideshow'));
    } else {
      unawaited(AppScreenKeepOn.release('slideshow'));
    }
  }

  Duration get _interval => _speeds[_speedIndex];

  Map<String, dynamic> get _photo => widget.photos[_index];

  void _restartTimer() {
    _timer?.cancel();
    if (_paused) return;
    _timer = Timer(_interval, _onTick);
  }

  void _advanceTo(int next, {required int effectKind}) {
    if (next == _index) return;
    setState(() {
      _outgoingIndex = _index;
      _outgoingOnTop = next < _index;
      _index = next;
      _effectKind = effectKind;
      _dragDx = 0;
    });
    _transitionCtrl.forward(from: 0);
    _restartTimer();
  }

  void _onTick() {
    if (!mounted || _paused) return;
    if (_index >= widget.photos.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    _advanceTo(
      _index + 1,
      effectKind: (_effectKind + 1) % _effectCount,
    );
  }

  void _goNext({bool manual = false}) {
    if (_index >= widget.photos.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    _advanceTo(
      _index + 1,
      effectKind: manual ? 1 : (_effectKind + 1) % _effectCount,
    );
  }

  void _goPrev() {
    if (_index <= 0) return;
    _advanceTo(_index - 1, effectKind: 5);
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
    // Только лёгкие превью — полный кадр на web валит память.
    if (local is Uint8List &&
        local.isNotEmpty &&
        local.length <= 400 * 1024) {
      return Image.memory(local, fit: BoxFit.contain, gaplessPlayback: true);
    }
    final threadId = photo['thread_id'] is int
        ? photo['thread_id'] as int
        : int.tryParse('${photo['thread_id']}');
    // Как в gallery viewer / ленте: на web file_url без JWT не открывается.
    if (threadId != null && threadId > 0) {
      return ChatNetworkImage(
        threadId: threadId,
        attachment: photo,
        fit: BoxFit.contain,
      );
    }
    final url = galleryAttachmentUrl(photo);
    if (url.isNotEmpty) {
      return FamilyPublicImage(
        url: url,
        fit: BoxFit.contain,
        placeholder: const ColoredBox(
          color: Colors.black,
          child: Center(
            child: CircularProgressIndicator(color: Colors.white54),
          ),
        ),
        error: const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 48,
            ),
          ),
        ),
      );
    }
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 48,
        ),
      ),
    );
  }

  Widget _photoLayer({
    required Map<String, dynamic> photo,
    required int keyIndex,
  }) {
    return KeyedSubtree(
      key: ValueKey<int>(keyIndex),
      child: SizedBox.expand(child: _buildMedia(photo)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _interval.inSeconds;
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

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
            child: AnimatedBuilder(
              animation: _transitionCtrl,
              builder: (context, _) {
                final t = Curves.easeInOutCubic.transform(_transitionCtrl.value);
                final incoming = _photoLayer(photo: _photo, keyIndex: _index);
                final outgoing = _outgoingIndex == null
                    ? null
                    : _photoLayer(
                        photo: widget.photos[_outgoingIndex!],
                        keyIndex: _outgoingIndex!,
                      );

                if (outgoing == null || !_transitionCtrl.isAnimating) {
                  return incoming;
                }

                final revealIncoming = !_outgoingOnTop;
                final progress = revealIncoming ? t : (1 - t);
                final under = revealIncoming ? outgoing : incoming;
                final over = revealIncoming
                    ? _SlideshowEffect(
                        progress: progress,
                        effectKind: _effectKind,
                        child: incoming,
                      )
                    : _SlideshowEffect(
                        progress: progress,
                        effectKind: _effectKind,
                        child: outgoing,
                      );

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    under,
                    over,
                  ],
                );
              },
            ),
          ),
          // Закрыть и нумерация — сверху на фото.
          Positioned(
            top: topPad + 8,
            left: 8,
            child: _ChromeButton(
              tooltip: 'Закрыть',
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Icon(Icons.close, color: Colors.white, size: 22),
            ),
          ),
          Positioned(
            top: topPad + 8,
            right: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  '${_index + 1} / ${widget.photos.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomPad + 16,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
        ],
      ),
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.child,
    required this.onPressed,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(width: 40, height: 40, child: Center(child: child)),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Эффекты появления следующего кадра.
class _SlideshowEffect extends StatelessWidget {
  const _SlideshowEffect({
    required this.progress,
    required this.effectKind,
    required this.child,
  });

  final double progress;
  final int effectKind;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    switch (effectKind % _PhotoSlideshowScreenState._effectCount) {
      case 0: // fade
        return Opacity(opacity: p, child: child);
      case 1: // clock wipe
        return ClipPath(
          clipper: _ClockWipeClipper(p),
          child: child,
        );
      case 2: // checkerboard
        return ClipPath(
          clipper: _CheckerboardClipper(p),
          child: child,
        );
      case 3: // horizontal blinds
        return ClipPath(
          clipper: _BlindsClipper(p, horizontal: true),
          child: child,
        );
      case 4: // iris
        return ClipPath(
          clipper: _IrisClipper(p),
          child: child,
        );
      case 5: // vertical wipe
        return ClipRect(
          clipper: _RectProgressClipper(p),
          child: child,
        );
      default: // diamond / radial squares feel via blinds vertical
        return ClipPath(
          clipper: _BlindsClipper(p, horizontal: false),
          child: child,
        );
    }
  }
}

class _ClockWipeClipper extends CustomClipper<Path> {
  _ClockWipeClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    if (progress <= 0) return Path();
    if (progress >= 1) {
      return Path()..addRect(Offset.zero & size);
    }
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    final sweep = progress * math.pi * 2;
    final start = -math.pi / 2;
    return Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        false,
      )
      ..close();
  }

  @override
  bool shouldReclip(covariant _ClockWipeClipper oldClipper) =>
      oldClipper.progress != progress;
}

class _CheckerboardClipper extends CustomClipper<Path> {
  _CheckerboardClipper(this.progress);

  final double progress;
  static const _cols = 6;
  static const _rows = 10;

  @override
  Path getClip(Size size) {
    final path = Path();
    if (progress <= 0) return path;
    final cellW = size.width / _cols;
    final cellH = size.height / _rows;
    final total = _cols * _rows;
    final visible = (progress * total).ceil();
    // Диагональный порядок появления квадратиков.
    final order = <(int, int)>[];
    for (var sum = 0; sum <= _cols + _rows - 2; sum++) {
      for (var c = 0; c < _cols; c++) {
        final r = sum - c;
        if (r >= 0 && r < _rows) order.add((c, r));
      }
    }
    for (var i = 0; i < visible && i < order.length; i++) {
      final (c, r) = order[i];
      path.addRect(Rect.fromLTWH(c * cellW, r * cellH, cellW + 0.5, cellH + 0.5));
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _CheckerboardClipper oldClipper) =>
      oldClipper.progress != progress;
}

class _BlindsClipper extends CustomClipper<Path> {
  _BlindsClipper(this.progress, {required this.horizontal});

  final double progress;
  final bool horizontal;
  static const _stripes = 12;

  @override
  Path getClip(Size size) {
    final path = Path();
    if (progress <= 0) return path;
    if (horizontal) {
      final h = size.height / _stripes;
      for (var i = 0; i < _stripes; i++) {
        final open = (h * progress).clamp(0.0, h);
        path.addRect(Rect.fromLTWH(0, i * h, size.width, open));
      }
    } else {
      final w = size.width / _stripes;
      for (var i = 0; i < _stripes; i++) {
        final open = (w * progress).clamp(0.0, w);
        path.addRect(Rect.fromLTWH(i * w, 0, open, size.height));
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _BlindsClipper oldClipper) =>
      oldClipper.progress != progress || oldClipper.horizontal != horizontal;
}

class _IrisClipper extends CustomClipper<Path> {
  _IrisClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    if (progress <= 0) return Path();
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.sqrt(
          size.width * size.width + size.height * size.height,
        ) /
        2;
    return Path()
      ..addOval(Rect.fromCircle(center: center, radius: maxR * progress));
  }

  @override
  bool shouldReclip(covariant _IrisClipper oldClipper) =>
      oldClipper.progress != progress;
}

class _RectProgressClipper extends CustomClipper<Rect> {
  _RectProgressClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) {
    final full = Offset.zero & size;
    if (progress <= 0) return Rect.zero;
    if (progress >= 1) return full;
    return Rect.fromLTWH(0, 0, size.width * progress, size.height);
  }

  @override
  bool shouldReclip(covariant _RectProgressClipper oldClipper) =>
      oldClipper.progress != progress;
}
