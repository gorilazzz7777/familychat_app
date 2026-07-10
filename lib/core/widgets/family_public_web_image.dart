import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'family_public_image_url.dart';

/// На web аватары из S3 грузятся через API (JWT), иначе CORS блокирует XHR.
class FamilyPublicWebImage extends ConsumerStatefulWidget {
  const FamilyPublicWebImage({
    super.key,
    required this.url,
    this.userId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.error,
  });

  final String url;
  final int? userId;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? error;

  @override
  ConsumerState<FamilyPublicWebImage> createState() =>
      _FamilyPublicWebImageState();
}

class _FamilyPublicWebImageState extends ConsumerState<FamilyPublicWebImage> {
  static const _maxAttempts = 3;
  static final Map<int, Uint8List> _memoryCache = <int, Uint8List>{};

  int _attempt = 0;
  bool _autoRetryScheduled = false;
  bool _loading = false;
  bool _failed = false;
  Uint8List? _bytes;

  int? get _resolvedUserId =>
      widget.userId ?? userIdFromFamilychatProfileAvatarUrl(widget.url);

  bool get _useApiProxy => _resolvedUserId != null;

  @override
  void initState() {
    super.initState();
    if (_useApiProxy) {
      _loading = true;
      unawaited(_loadAvatarBytes());
    }
  }

  @override
  void didUpdateWidget(covariant FamilyPublicWebImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_useApiProxy) return;
    final oldUserId =
        oldWidget.userId ?? userIdFromFamilychatProfileAvatarUrl(oldWidget.url);
    final newUserId = _resolvedUserId;
    if (oldUserId != newUserId || oldWidget.url != widget.url) {
      _attempt = 0;
      _failed = false;
      _bytes = null;
      _loading = true;
      unawaited(_loadAvatarBytes());
    }
  }

  Future<void> _loadAvatarBytes({int attempt = 0}) async {
    final userId = _resolvedUserId;
    if (userId == null) return;

    final memoryCached = _memoryCache[userId];
    if (memoryCached != null && memoryCached.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _bytes = memoryCached;
        _failed = false;
        _loading = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _loading = true;
      _failed = false;
    });

    try {
      final bytes =
          await ref.read(familychatRepositoryProvider).fetchMemberAvatarBytes(
                userId,
              );
      _memoryCache[userId] = bytes;
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _failed = false;
        _loading = false;
      });
    } catch (_) {
      final recovered = _memoryCache[userId];
      if (recovered != null && recovered.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _bytes = recovered;
          _failed = false;
          _loading = false;
        });
        return;
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
        if (!mounted) return;
        await _loadAvatarBytes(attempt: attempt + 1);
        return;
      }
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
        _bytes = null;
      });
    }
  }

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
    if (_useApiProxy) {
      setState(() {
        _attempt += 1;
        _failed = false;
        _loading = true;
        _bytes = null;
      });
      unawaited(_loadAvatarBytes());
      return;
    }
    setState(() => _attempt += 1);
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.placeholder ?? _defaultPlaceholder(context);
    final errorWidget = widget.error ?? _defaultError(context);

    if (_useApiProxy) {
      if (_failed) {
        return GestureDetector(
          onTap: _retry,
          behavior: HitTestBehavior.opaque,
          child: errorWidget,
        );
      }
      if (_loading && _bytes == null) return placeholder;
      if (_bytes == null) return placeholder;
      return Image.memory(
        _bytes!,
        key: ValueKey('avatar:${_resolvedUserId!}#$_attempt'),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => GestureDetector(
          onTap: _retry,
          behavior: HitTestBehavior.opaque,
          child: errorWidget,
        ),
      );
    }

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
