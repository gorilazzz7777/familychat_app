import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cache/familychat_local_cache.dart';
import '../../../../core/cache/familychat_media_cache.dart';
import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/local_device_file.dart';
import '../../../../core/media/media_local_index.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/widgets/web_image_cache_registry.dart';
import '../../../familychat/data/familychat_repository.dart';
import '../../data/chat_realtime_utils.dart';

final _attachmentBytesCache = <String, Uint8List>{};

String _attachmentCacheKey(int threadId, int attachmentId) =>
    '$threadId:$attachmentId';

/// Изображение вложения чата.
///
/// Текст/рамки рисуются сразу; байты догружаются в фоне с лимитом параллелизма.
/// На web и при пустом `file_url` — через API (JWT).
/// На native с `file_url` — CachedNetworkImage.
class ChatNetworkImage extends ConsumerStatefulWidget {
  const ChatNetworkImage({
    super.key,
    required this.threadId,
    required this.attachment,
    this.height,
    this.width,
    this.fit = BoxFit.cover,
    this.onResolvedSize,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double? height;
  final double? width;
  final BoxFit fit;
  final ValueChanged<Size>? onResolvedSize;

  @override
  ConsumerState<ChatNetworkImage> createState() => _ChatNetworkImageState();
}

class _ChatNetworkImageState extends ConsumerState<ChatNetworkImage> {
  Map<String, String>? _headers;
  bool _bytesFailed = false;
  bool _loadStarted = false;
  bool _wantsNetworkLoad = false;
  bool _sizeReported = false;
  bool _sizeListenAttached = false;

  int? get _attachmentId => chatAsInt(widget.attachment['id']);

  void _reportSize(int width, int height) {
    if (_sizeReported || widget.onResolvedSize == null) return;
    if (width <= 0 || height <= 0) return;
    _sizeReported = true;
    final size = Size(width.toDouble(), height.toDouble());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onResolvedSize?.call(size);
    });
  }

  void _listenProviderSize(ImageProvider provider) {
    if (widget.onResolvedSize == null ||
        _sizeReported ||
        _sizeListenAttached) {
      return;
    }
    _sizeListenAttached = true;
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        _reportSize(info.image.width, info.image.height);
        stream.removeListener(listener);
      },
      onError: (_, __) {
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  Widget _sizedImage({
    required ImageProvider provider,
    Key? key,
    ImageErrorWidgetBuilder? errorBuilder,
  }) {
    _listenProviderSize(provider);
    return Image(
      key: key,
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      errorBuilder: errorBuilder,
    );
  }

  String? get _registryKey {
    final attachmentId = _attachmentId;
    if (attachmentId == null) return null;
    return WebImageCacheRegistry.attachmentKey(widget.threadId, attachmentId);
  }

  bool get _useBytesPath {
    if (kIsWeb) return true;
    return _imageUrl(ref.read(familychatRepositoryProvider)).isEmpty;
  }

  @override
  void initState() {
    super.initState();
    if (_useBytesPath) {
      // Сначала даём отрисовать текст и рамки, сеть — после кадра / из кэша.
      final cached = _cachedBytes();
      if (cached != null) {
        _ensureBytesLoadStarted();
      } else {
        _scheduleDeferredNetworkLoad();
      }
    } else {
      _loadHeaders();
    }
  }

  @override
  void didUpdateWidget(covariant ChatNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = chatAsInt(oldWidget.attachment['id']);
    final newId = _attachmentId;
    final urlChanged =
        oldWidget.attachment['file_url'] != widget.attachment['file_url'];
    if (oldId != newId || oldWidget.threadId != widget.threadId || urlChanged) {
      _bytesFailed = false;
      _loadStarted = false;
      _wantsNetworkLoad = false;
      _sizeReported = false;
      _sizeListenAttached = false;
      if (_useBytesPath) {
        final cached = _cachedBytes();
        if (cached != null) {
          _ensureBytesLoadStarted();
        } else {
          _scheduleDeferredNetworkLoad();
        }
      } else {
        _loadHeaders();
        setState(() {});
      }
    }
  }

  void _scheduleDeferredNetworkLoad() {
    if (_wantsNetworkLoad) return;
    _wantsNetworkLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_wantsNetworkLoad) return;
      // Ещё один кадр — список сообщений успевает отрисоваться.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_wantsNetworkLoad) return;
        _ensureBytesLoadStarted();
      });
    });
  }

  Future<void> _loadHeaders() async {
    final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
    if (!mounted || token == null || token.isEmpty) return;
    setState(() => _headers = {'Authorization': 'Bearer $token'});
  }

  void _ensureBytesLoadStarted() {
    final local = widget.attachment['local_bytes'];
    if (local is Uint8List && local.isNotEmpty) return;
    if (_loadStarted) return;
    _loadStarted = true;
    unawaited(_loadBytes());
  }

  void _notifyCacheUpdated() {
    final key = _registryKey;
    if (key != null) {
      WebImageCacheRegistry.notifyUpdated(key);
    }
  }

  Uint8List? _cachedBytes() {
    final attachmentId = _attachmentId;
    if (attachmentId == null) return null;

    final cacheKey = _attachmentCacheKey(widget.threadId, attachmentId);
    final memoryCached = _attachmentBytesCache[cacheKey];
    if (memoryCached != null && memoryCached.isNotEmpty) {
      return memoryCached;
    }
    return FamilyChatRepository.peekChatAttachmentBytes(
      widget.threadId,
      attachmentId,
    );
  }

  Future<void> _loadBytes({int attempt = 0}) async {
    final local = widget.attachment['local_bytes'];
    if (local is Uint8List && local.isNotEmpty) {
      if (mounted) setState(() => _bytesFailed = false);
      return;
    }
    final attachmentId = _attachmentId;
    if (attachmentId == null) {
      if (mounted) setState(() => _bytesFailed = true);
      return;
    }

    final cacheKey = _attachmentCacheKey(widget.threadId, attachmentId);
    final cached = _cachedBytes();
    if (cached != null) {
      _attachmentBytesCache[cacheKey] = cached;
      _notifyCacheUpdated();
      if (mounted) setState(() => _bytesFailed = false);
      return;
    }

    try {
      final stored = await FamilyChatLocalCache.readAttachmentBytes(
        widget.threadId,
        attachmentId,
      );
      if (stored != null && stored.isNotEmpty) {
        _attachmentBytesCache[cacheKey] = stored;
        _notifyCacheUpdated();
        if (mounted) setState(() => _bytesFailed = false);
        return;
      }

      final bytes =
          await ref.read(familychatRepositoryProvider).fetchChatAttachmentBytes(
                widget.threadId,
                attachmentId,
              );
      _attachmentBytesCache[cacheKey] = bytes;
      unawaited(
        FamilyChatLocalCache.saveAttachmentBytes(
          widget.threadId,
          attachmentId,
          bytes,
        ).catchError((_) {}),
      );
      _notifyCacheUpdated();
      if (mounted) setState(() => _bytesFailed = false);
    } catch (_) {
      final recovered = _cachedBytes();
      if (recovered != null) {
        _attachmentBytesCache[cacheKey] = recovered;
        _notifyCacheUpdated();
        if (mounted) setState(() => _bytesFailed = false);
        return;
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
        if (!mounted) return;
        await _loadBytes(attempt: attempt + 1);
        return;
      }
      if (!mounted) return;
      setState(() => _bytesFailed = true);
    }
  }

  String _imageUrl(FamilyChatRepository repo) {
    return widget.attachment['file_url']?.toString() ?? '';
  }

  Widget _errorBox({bool retryable = true}) {
    return GestureDetector(
      onTap: retryable && _useBytesPath
          ? () {
              setState(() => _bytesFailed = false);
              _loadStarted = false;
              _wantsNetworkLoad = false;
              _ensureBytesLoadStarted();
            }
          : null,
      child: SizedBox(
        height: widget.height,
        width: widget.width,
        child: ColoredBox(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.55),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.image_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              if (retryable && _useBytesPath) ...[
                const SizedBox(height: 4),
                Text(
                  'Повторить',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Рамка-заглушка без спиннера — текст чата читается сразу.
  Widget _framePlaceholder() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: widget.width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        child: Icon(
          Icons.image_outlined,
          size: 28,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
        ),
      ),
    );
  }

  Widget _buildBytesImage() {
    final registryKey = _registryKey;
    if (registryKey == null) return _errorBox();

    return ValueListenableBuilder<int>(
      valueListenable: WebImageCacheRegistry.listenable(registryKey),
      builder: (context, _, __) {
        if (_bytesFailed) return _errorBox();

        final bytes = _cachedBytes();
        if (bytes == null) return _framePlaceholder();

        return _sizedImage(
          provider: MemoryImage(bytes),
          key: ValueKey('${widget.threadId}:${widget.attachment['id']}'),
          errorBuilder: (_, __, ___) => _errorBox(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    MediaLocalIndex.hydrateAttachment(widget.attachment);
    final localPath = galleryLocalDevicePath(widget.attachment);
    if (localDeviceFileExists(localPath)) {
      final localImage = localDeviceFileImage(
        path: localPath,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        error: _errorBox(retryable: false),
      );
      if (localImage is Image) {
        _listenProviderSize(localImage.image);
      }
      return localImage;
    }

    final local = widget.attachment['local_bytes'];
    if (isSafeUiPreviewBytes(local)) {
      return _sizedImage(
        provider: MemoryImage(local as Uint8List),
        errorBuilder: (_, __, ___) => _errorBox(retryable: false),
      );
    }

    if (_useBytesPath) {
      return _buildBytesImage();
    }

    final url = _imageUrl(ref.read(familychatRepositoryProvider));
    if (url.isEmpty) return _errorBox(retryable: false);

    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: _headers,
      cacheManager: FamilyChatMediaCache.preview,
      useOldImageOnUrlChange: true,
      height: widget.height,
      width: widget.width,
      fit: widget.fit,
      placeholder: (_, __) => _framePlaceholder(),
      errorWidget: (_, __, ___) => _errorBox(retryable: false),
      imageBuilder: (context, imageProvider) {
        unawaited(FamilyChatMediaCache.trimIfNeeded());
        return _sizedImage(provider: imageProvider);
      },
    );
  }
}

String chatAttachmentImageUrl({
  required FamilyChatRepository repo,
  required int threadId,
  required Map<String, dynamic> attachment,
}) {
  final attachmentId = chatAsInt(attachment['id']);
  if (kIsWeb && attachmentId != null) {
    return repo.chatAttachmentContentUrl(threadId, attachmentId);
  }
  return attachment['file_url']?.toString() ?? '';
}

Future<Map<String, String>?> chatImageAuthHeaders(WidgetRef ref) async {
  if (!kIsWeb) return null;
  final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
  if (token == null || token.isEmpty) return null;
  return {'Authorization': 'Bearer $token'};
}

Future<Uint8List?> chatAttachmentBytesForViewer({
  required WidgetRef ref,
  required int? threadId,
  required int? attachmentId,
}) async {
  if (!kIsWeb || threadId == null || attachmentId == null) return null;
  final cacheKey = _attachmentCacheKey(threadId, attachmentId);
  final cached = _attachmentBytesCache[cacheKey];
  if (cached != null) return cached;
  final stored = await FamilyChatLocalCache.readAttachmentBytes(
    threadId,
    attachmentId,
  );
  if (stored != null && stored.isNotEmpty) {
    _attachmentBytesCache[cacheKey] = stored;
    WebImageCacheRegistry.notifyUpdated(
      WebImageCacheRegistry.attachmentKey(threadId, attachmentId),
    );
    return stored;
  }
  try {
    final bytes = await ref.read(familychatRepositoryProvider).fetchChatAttachmentBytes(
          threadId,
          attachmentId,
        );
    _attachmentBytesCache[cacheKey] = bytes;
    WebImageCacheRegistry.notifyUpdated(
      WebImageCacheRegistry.attachmentKey(threadId, attachmentId),
    );
    await FamilyChatLocalCache.saveAttachmentBytes(threadId, attachmentId, bytes);
    return bytes;
  } catch (_) {
    return null;
  }
}
