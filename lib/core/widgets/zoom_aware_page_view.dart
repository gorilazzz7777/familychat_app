import 'dart:math' as math;

import 'package:flutter/material.dart';

/// PageView, который не листает страницы, пока на экране 2+ пальца
/// или пока текущее фото увеличено (pinch / pan zoom).
class ZoomAwarePageView extends StatefulWidget {
  const ZoomAwarePageView({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
  });

  final PageController controller;
  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final ValueChanged<int>? onPageChanged;

  @override
  State<ZoomAwarePageView> createState() => ZoomAwarePageViewState();
}

class ZoomAwarePageViewState extends State<ZoomAwarePageView> {
  int _pointers = 0;
  double _scale = 1.0;

  bool get _lockScroll => _pointers >= 2 || _scale > 1.05;

  void reportScale(double scale) {
    final next = scale.clamp(0.2, 8.0);
    if ((next - _scale).abs() < 0.01) return;
    setState(() => _scale = next);
  }

  void resetScale() {
    if (_scale == 1.0) return;
    setState(() => _scale = 1.0);
  }

  void _onPointerDown(PointerDownEvent _) {
    setState(() => _pointers += 1);
  }

  void _onPointerUpOrCancel(PointerEvent _) {
    setState(() => _pointers = math.max(0, _pointers - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUpOrCancel,
      onPointerCancel: _onPointerUpOrCancel,
      child: PageView.builder(
        controller: widget.controller,
        itemCount: widget.itemCount,
        physics: _lockScroll
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        onPageChanged: (i) {
          resetScale();
          widget.onPageChanged?.call(i);
        },
        itemBuilder: widget.itemBuilder,
      ),
    );
  }
}

/// InteractiveViewer с отчётом масштаба наружу (для блокировки свайпа страниц).
class ScaleReportingInteractiveViewer extends StatefulWidget {
  const ScaleReportingInteractiveViewer({
    super.key,
    required this.child,
    this.minScale = 0.8,
    this.maxScale = 5,
    this.constrained = true,
    this.clipBehavior = Clip.hardEdge,
    this.onScaleChanged,
  });

  final Widget child;
  final double minScale;
  final double maxScale;
  final bool constrained;
  final Clip clipBehavior;
  final ValueChanged<double>? onScaleChanged;

  @override
  State<ScaleReportingInteractiveViewer> createState() =>
      _ScaleReportingInteractiveViewerState();
}

class _ScaleReportingInteractiveViewerState
    extends State<ScaleReportingInteractiveViewer> {
  final TransformationController _controller = TransformationController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_emitScale);
  }

  @override
  void dispose() {
    _controller.removeListener(_emitScale);
    _controller.dispose();
    super.dispose();
  }

  void _emitScale() {
    widget.onScaleChanged?.call(_controller.value.getMaxScaleOnAxis());
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _controller,
      minScale: widget.minScale,
      maxScale: widget.maxScale,
      constrained: widget.constrained,
      clipBehavior: widget.clipBehavior,
      onInteractionUpdate: (_) => _emitScale(),
      onInteractionEnd: (_) => _emitScale(),
      child: widget.child,
    );
  }
}