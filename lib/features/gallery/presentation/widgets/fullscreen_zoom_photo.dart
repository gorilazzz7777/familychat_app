import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/media/gallery_media_utils.dart';

/// Fullscreen photo with pinch zoom.
///
/// Starts at cover only when cropping ≤5% of the photo; otherwise contain
/// (original aspect, letterboxed). Pinch out can shrink further; pinch in
/// enlarges past the home scale.
class FullscreenZoomPhoto extends StatefulWidget {
  const FullscreenZoomPhoto({
    super.key,
    required this.imageBuilder,
    this.imageWidth,
    this.imageHeight,
    this.onScaleChanged,
    this.minContainFactor = 0.55,
    this.maxScale = 5,
  });

  /// Builds the image for a given [BoxFit] inside a viewport-sized box.
  final Widget Function(BoxFit fit) imageBuilder;
  final double? imageWidth;
  final double? imageHeight;
  final ValueChanged<double>? onScaleChanged;

  /// How small relative to contain (full frame) the user may go.
  final double minContainFactor;
  final double maxScale;

  @override
  State<FullscreenZoomPhoto> createState() => _FullscreenZoomPhotoState();
}

class _FullscreenZoomPhotoState extends State<FullscreenZoomPhoto> {
  final TransformationController _controller = TransformationController();
  double _imageW = 0;
  double _imageH = 0;
  Size? _viewport;
  double _homeScale = 1.0;
  bool _snapped = false;

  @override
  void initState() {
    super.initState();
    _imageW = widget.imageWidth ?? 0;
    _imageH = widget.imageHeight ?? 0;
    _controller.addListener(_emitScale);
  }

  @override
  void dispose() {
    _controller.removeListener(_emitScale);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FullscreenZoomPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    final w = widget.imageWidth ?? 0;
    final h = widget.imageHeight ?? 0;
    if (w > 0 &&
        h > 0 &&
        ((w - _imageW).abs() > 0.5 || (h - _imageH).abs() > 0.5)) {
      _applyResolvedSize(w, h);
    }
  }

  void applyResolvedSize(Size size) =>
      _applyResolvedSize(size.width, size.height);

  void _applyResolvedSize(double w, double h) {
    if (w <= 0 || h <= 0) return;
    if ((w - _imageW).abs() < 0.5 && (h - _imageH).abs() < 0.5) return;
    _imageW = w;
    _imageH = h;
    final vp = _viewport;
    if (vp != null && mounted) {
      _snapToHome(vp);
      setState(() {});
    }
  }

  void _emitScale() {
    final scale = _controller.value.getMaxScaleOnAxis();
    final home = _homeScale <= 0 ? 1.0 : _homeScale;
    widget.onScaleChanged?.call(scale / home);
  }

  void _snapToHome(Size viewport) {
    if (_imageW <= 0 || _imageH <= 0) {
      // Size unknown: BoxFit.cover at identity until pixels resolve.
      _homeScale = 1.0;
      _controller.value = Matrix4.identity();
      _snapped = true;
      _emitScale();
      return;
    }
    final home = galleryFullscreenHomeScale(
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
      imageWidth: _imageW,
      imageHeight: _imageH,
    );
    _homeScale = home;
    _controller.value = _centeredScale(viewport, home);
    _snapped = true;
    _emitScale();
  }

  Matrix4 _centeredScale(Size viewport, double scale) {
    final dx = viewport.width / 2;
    final dy = viewport.height / 2;
    final m = Matrix4.identity();
    m.translateByDouble(dx, dy, 0, 1);
    m.scaleByDouble(scale, scale, 1, 1);
    m.translateByDouble(-dx, -dy, 0, 1);
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final vpChanged = _viewport != viewport;
        _viewport = viewport;
        if (vpChanged || !_snapped) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _viewport != viewport) return;
            _snapToHome(viewport);
            if (mounted) setState(() {});
          });
        }

        final hasSize = _imageW > 0 && _imageH > 0;
        // Known size → contain + optional cover home scale (≤5% crop).
        // Unknown → cover until dimensions resolve.
        final fit = hasSize ? BoxFit.contain : BoxFit.cover;
        final minScale = hasSize
            ? math.min(widget.minContainFactor, 1.0)
            : widget.minContainFactor;
        final maxScale = math.max(widget.maxScale, _homeScale * widget.maxScale);

        return ClipRect(
          child: InteractiveViewer(
            transformationController: _controller,
            minScale: minScale,
            maxScale: maxScale,
            constrained: true,
            clipBehavior: Clip.hardEdge,
            panEnabled: true,
            scaleEnabled: true,
            onInteractionUpdate: (_) => _emitScale(),
            onInteractionEnd: (_) => _emitScale(),
            child: SizedBox(
              width: viewport.width,
              height: viewport.height,
              child: widget.imageBuilder(fit),
            ),
          ),
        );
      },
    );
  }
}

/// Attachment-aware zoom photo; learns pixel size from metadata or [onResolvedSize].
class FullscreenZoomAttachmentPhoto extends StatefulWidget {
  const FullscreenZoomAttachmentPhoto({
    super.key,
    required this.attachment,
    required this.imageBuilder,
    this.onScaleChanged,
  });

  final Map<String, dynamic> attachment;
  final Widget Function(BoxFit fit, ValueChanged<Size>? onResolvedSize)
      imageBuilder;
  final ValueChanged<double>? onScaleChanged;

  @override
  State<FullscreenZoomAttachmentPhoto> createState() =>
      _FullscreenZoomAttachmentPhotoState();
}

class _FullscreenZoomAttachmentPhotoState
    extends State<FullscreenZoomAttachmentPhoto> {
  final GlobalKey<_FullscreenZoomPhotoState> _zoomKey =
      GlobalKey<_FullscreenZoomPhotoState>();
  double? _w;
  double? _h;

  @override
  void initState() {
    super.initState();
    final size = galleryAttachmentPixelSize(widget.attachment);
    _w = size?.width;
    _h = size?.height;
  }

  @override
  void didUpdateWidget(covariant FullscreenZoomAttachmentPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.attachment, widget.attachment)) {
      final size = galleryAttachmentPixelSize(widget.attachment);
      if (size != null) {
        _w = size.width;
        _h = size.height;
      }
    }
  }

  void _onResolvedSize(Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _zoomKey.currentState?.applyResolvedSize(size);
    if (_w == size.width && _h == size.height) return;
    setState(() {
      _w = size.width;
      _h = size.height;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FullscreenZoomPhoto(
      key: _zoomKey,
      imageWidth: _w,
      imageHeight: _h,
      onScaleChanged: widget.onScaleChanged,
      imageBuilder: (fit) => widget.imageBuilder(fit, _onResolvedSize),
    );
  }
}
