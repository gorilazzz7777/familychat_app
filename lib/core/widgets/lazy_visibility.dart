import 'package:flutter/widgets.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Запускает [onVisible] один раз, когда виджет попадает в viewport.
class LazyVisibility extends StatefulWidget {
  const LazyVisibility({
    super.key,
    required this.child,
    required this.onVisible,
    this.visibilityKey,
    this.visibleFraction = 0.08,
  });

  final Widget child;
  final VoidCallback onVisible;
  final Key? visibilityKey;
  final double visibleFraction;

  @override
  State<LazyVisibility> createState() => _LazyVisibilityState();
}

class _LazyVisibilityState extends State<LazyVisibility> {
  var _fired = false;

  void _handleVisibility(VisibilityInfo info) {
    if (_fired || !mounted) return;
    if (info.visibleFraction < widget.visibleFraction) return;
    _fired = true;
    widget.onVisible();
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: widget.visibilityKey ?? ValueKey(widget.hashCode),
      onVisibilityChanged: _handleVisibility,
      child: widget.child,
    );
  }
}
