import 'dart:async';

import 'package:flutter/material.dart';

/// [Image.network] для Safari/iOS web: frameBuilder + авто-повтор при ошибке.
class FamilyPublicWebImage extends StatefulWidget {
  const FamilyPublicWebImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.error,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? error;

  @override
  State<FamilyPublicWebImage> createState() => _FamilyPublicWebImageState();
}

class _FamilyPublicWebImageState extends State<FamilyPublicWebImage> {
  static const _maxAttempts = 3;

  int _attempt = 0;
  bool _autoRetryScheduled = false;

  void _scheduleAutoRetry() {
    if (_autoRetryScheduled || _attempt >= _maxAttempts - 1) return;
    _autoRetryScheduled = true;
    unawaited(
      Future<void>.delayed(Duration(milliseconds: 350 * (_attempt + 1)), () {
        if (!mounted) return;
        setState(() {
          _attempt += 1;
          _autoRetryScheduled = false;
        });
      }),
    );
  }

  void _retry() {
    setState(() => _attempt += 1);
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.placeholder ?? _defaultPlaceholder(context);
    final errorWidget = widget.error ?? _defaultError(context);

    return Image.network(
      widget.url,
      key: ValueKey('${widget.url}#$_attempt'),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return placeholder;
      },
      errorBuilder: (context, error, stackTrace) {
        _scheduleAutoRetry();
        return GestureDetector(
          onTap: _retry,
          behavior: HitTestBehavior.opaque,
          child: errorWidget,
        );
      },
    );
  }

  Widget _defaultPlaceholder(BuildContext context) {
    return SizedBox(
      width: widget.width ?? double.infinity,
      height: widget.height ?? double.infinity,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }

  Widget _defaultError(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.person_outline,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
