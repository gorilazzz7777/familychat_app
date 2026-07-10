import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../providers/app_providers.dart';
import 'family_public_image_url.dart';
import 'web_image_cache_registry.dart';

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

  int _attempt = 0;
  bool _autoRetryScheduled = false;
  bool _failed = false;
  bool _loadStarted = false;

  int? get _resolvedUserId =>
      widget.userId ?? userIdFromFamilychatProfileAvatarUrl(widget.url);

  bool get _useApiProxy => _resolvedUserId != null;

  String? get _cacheKey {
    final userId = _resolvedUserId;
    if (userId == null) return null;
    return WebImageCacheRegistry.avatarKey(userId);
  }

  @override
  void initState() {
    super.initState();
    if (_useApiProxy) {
      _ensureLoadStarted();
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
      _loadStarted = false;
      _ensureLoadStarted();
    }
  }

  void _ensureLoadStarted() {
    if (_loadStarted) return;
    _loadStarted = true;
    unawaited(_loadAvatarBytes());
  }

  void _notifyCacheUpdated() {
    final key = _cacheKey;
    if (key != null) {
      WebImageCacheRegistry.notifyUpdated(key);
    }
  }

  Uint8List? _cachedBytes() {
    final userId = _resolvedUserId;
    if (userId == null) return null;
    return FamilyChatRepository.peekMemberAvatarBytes(userId);
  }

  Future<void> _loadAvatarBytes({int attempt = 0}) async {
    final userId = _resolvedUserId;
    if (userId == null) return;

    final cached = _cachedBytes();
    if (cached != null) {
      _notifyCacheUpdated();
      if (mounted) setState(() => _failed = false);
      return;
    }

    try {
      await ref.read(familychatRepositoryProvider).fetchMemberAvatarBytes(
            userId,
          );
      _notifyCacheUpdated();
      if (mounted) {
        setState(() => _failed = false);
      }
    } catch (_) {
      final recovered = _cachedBytes();
      if (recovered != null) {
        _notifyCacheUpdated();
        if (mounted) setState(() => _failed = false);
        return;
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
        if (!mounted) return;
        await _loadAvatarBytes(attempt: attempt + 1);
        return;
      }
      if (!mounted) return;
      setState(() => _failed = true);
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
      });
      unawaited(_loadAvatarBytes());
      return;
    }
    setState(() => _attempt += 1);
  }

  Widget _buildApiProxy(BuildContext context) {
    final placeholder = widget.placeholder ?? _defaultPlaceholder(context);
    final errorWidget = widget.error ?? _defaultError(context);
    final cacheKey = _cacheKey;
    if (cacheKey == null) return placeholder;

    return ValueListenableBuilder<int>(
      valueListenable: WebImageCacheRegistry.listenable(cacheKey),
      builder: (context, _, __) {
        if (_failed) {
          return GestureDetector(
            onTap: _retry,
            behavior: HitTestBehavior.opaque,
            child: errorWidget,
          );
        }

        final bytes = _cachedBytes();
        if (bytes == null) return placeholder;

        return Image.memory(
          bytes,
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_useApiProxy) {
      return _buildApiProxy(context);
    }

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
