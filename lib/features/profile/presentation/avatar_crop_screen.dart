import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Превью аватара с перемещением и масштабированием перед загрузкой.
class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  static Future<Uint8List?> open(
    BuildContext context, {
    required Uint8List imageBytes,
  }) {
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AvatarCropScreen(imageBytes: imageBytes),
      ),
    );
  }

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  ui.Image? _decodedImage;
  var _busy = false;
  var _cropReady = false;

  Size? _viewportSize;
  double? _cropSize;

  double _baseScale = 1;
  double _zoom = 1;
  Offset _offset = Offset.zero;

  Offset _gestureFocalStart = Offset.zero;
  Offset _gestureOffsetStart = Offset.zero;
  double _gestureZoomStart = 1;

  static const _minZoom = 0.6;
  static const _maxZoom = 4.0;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() => _decodedImage = frame.image);
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryInitLayout());
  }

  double get _totalScale => _baseScale * _zoom;

  Size get _imageSize {
    final image = _decodedImage!;
    return Size(image.width.toDouble(), image.height.toDouble());
  }

  void _resetTransform(Size viewport) {
    final imageSize = _imageSize;
    _baseScale = math.max(
      viewport.width / imageSize.width,
      viewport.height / imageSize.height,
    );
    _zoom = 1;
    final displayW = imageSize.width * _totalScale;
    final displayH = imageSize.height * _totalScale;
    _offset = Offset(
      (viewport.width - displayW) / 2,
      (viewport.height - displayH) / 2,
    );
  }

  void _tryInitLayout() {
    final viewport = _viewportSize;
    final image = _decodedImage;
    if (viewport == null || image == null || _cropReady) return;
    _resetTransform(viewport);
    _cropReady = true;
    setState(() {});
  }

  void _onViewportChanged(Size viewport, double cropSize) {
    final prev = _viewportSize;
    _viewportSize = viewport;
    _cropSize = cropSize;

    if (_decodedImage == null) return;
    if (!_cropReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryInitLayout());
      return;
    }
    if (prev != viewport) {
      _resetTransform(viewport);
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureFocalStart = details.focalPoint;
    _gestureOffsetStart = _offset;
    _gestureZoomStart = _zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      final nextZoom =
          (_gestureZoomStart * details.scale).clamp(_minZoom, _maxZoom);
      if (details.scale == 1.0) {
        _offset = _gestureOffsetStart + details.focalPoint - _gestureFocalStart;
      } else {
        final ratio = nextZoom / _gestureZoomStart;
        _offset = details.focalPoint -
            (_gestureFocalStart - _gestureOffsetStart) * ratio;
      }
      _zoom = nextZoom;
    });
  }

  Rect _cropRectInImage(Size viewport, double cropSize) {
    final image = _decodedImage!;
    final scale = _totalScale;
    final center = viewport.center(Offset.zero);
    final half = cropSize / 2;

    var left = (center.dx - half - _offset.dx) / scale;
    var top = (center.dy - half - _offset.dy) / scale;
    var right = (center.dx + half - _offset.dx) / scale;
    var bottom = (center.dy + half - _offset.dy) / scale;

    left = left.clamp(0.0, image.width.toDouble());
    top = top.clamp(0.0, image.height.toDouble());
    right = right.clamp(0.0, image.width.toDouble());
    bottom = bottom.clamp(0.0, image.height.toDouble());

    if (right <= left) right = math.min(image.width.toDouble(), left + 1);
    if (bottom <= top) bottom = math.min(image.height.toDouble(), top + 1);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Future<void> _crop(Size viewport, double cropSize) async {
    final image = _decodedImage;
    if (_busy || image == null) return;
    setState(() => _busy = true);
    try {
      final srcRect = _cropRectInImage(viewport, cropSize);
      const outputSize = 512.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        srcRect,
        const Rect.fromLTWH(0, 0, outputSize, outputSize),
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final output =
          await picture.toImage(outputSize.toInt(), outputSize.toInt());
      final bytes = await output.toByteData(format: ui.ImageByteFormat.png);
      output.dispose();
      if (!mounted || bytes == null) return;
      Navigator.of(context).pop(bytes.buffer.asUint8List());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось обрезать фото: $e')),
      );
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final image = _decodedImage;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        title: const Text('Фото профиля'),
        actions: [
          TextButton(
            onPressed: _busy || !_cropReady
                ? null
                : () => _crop(_viewportSize!, _cropSize!),
            child: _busy
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  )
                : const Text('Готово'),
          ),
        ],
      ),
      body: image == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Text(
                    'Перемещайте и масштабируйте фото, чтобы отцентровать лицо в кружке',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final viewport = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      final cropSize =
                          math.min(viewport.width, viewport.height) * 0.72;
                      _onViewportChanged(viewport, cropSize);

                      final imageSize = _imageSize;
                      final displayW = imageSize.width * _totalScale;
                      final displayH = imageSize.height * _totalScale;

                      return GestureDetector(
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        child: ClipRect(
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              Positioned(
                                left: _offset.dx,
                                top: _offset.dy,
                                width: displayW,
                                height: displayH,
                                child: RawImage(
                                  image: image,
                                  fit: BoxFit.fill,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                              IgnorePointer(
                                child: CustomPaint(
                                  size: viewport,
                                  painter: _AvatarCropMaskPainter(
                                    cropSize: cropSize,
                                    borderColor: cs.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Text(
                      'Сведите или разведите пальцы для масштаба',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _AvatarCropMaskPainter extends CustomPainter {
  const _AvatarCropMaskPainter({
    required this.cropSize,
    required this.borderColor,
  });

  final double cropSize;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final hole = Rect.fromCenter(
      center: center,
      width: cropSize,
      height: cropSize,
    );

    final overlay = Path()..addRect(Offset.zero & size);
    final holePath = Path()..addOval(hole);
    final mask = Path.combine(PathOperation.difference, overlay, holePath);

    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawOval(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = borderColor,
    );
  }

  @override
  bool shouldRepaint(covariant _AvatarCropMaskPainter oldDelegate) {
    return oldDelegate.cropSize != cropSize ||
        oldDelegate.borderColor != borderColor;
  }
}
