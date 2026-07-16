import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cache/familychat_local_cache.dart';
import '../../../../core/cache/familychat_media_cache.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/widgets/web_image_cache_registry.dart';
import '../../../familychat/data/familychat_repository.dart';
import '../../data/chat_realtime_utils.dart';

final _attachmentBytesCache = <String, Uint8List>{};

String _attachmentCacheKey(int threadId, int attachmentId) =>
    '$threadId:$attachmentId';

/// Изображение вложения чата.
///
/// На web и при пустом `file_url` — байты через API (JWT).
/// На native с `file_url` — CachedNetworkImage.
class ChatNetworkImage extends ConsumerStatefulWidget {
  const ChatNetworkImage({
    super.key,
    required this.threadId,
    required this.attachment,
    this.height,
    this.width,
    this.fit = BoxFit.cover,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double? height;
  final double? width;
  final BoxFit fit;

  @override
  ConsumerState<ChatNetworkImage> createState() => _ChatNetworkImageState();
}

class _ChatNetworkImageState extends ConsumerState<ChatNetworkImage> {
  Map<String, String>? _headers;
  bool _bytesFailed = false;
  bool _loadStarted = false;

  int? get _attachmentId => chatAsInt(widget.attachment['id']);

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
      _ensureBytesLoadStarted();
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
      if (_useBytesPath) {
        _ensureBytesLoadStarted();
      } else {
        _loadHeaders();
        setState(() {});
      }
    }
  }

  Future<void> _loadHeaders() async {
    final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
    if (!mounted || token == null || token.isEmpty) return;
    setState(() => _headers = {'Authorization': 'Bearer $token'});
  }

  void _ensureBytesLoadStarted() {
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
              _ensureBytesLoadStarted();
            }
          : null,
      child: SizedBox(
        height: widget.height,
        width: widget.width,
        child: ColoredBox(
          color: const Color(0x11000000),
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

  Widget _loadingBox() {
    return SizedBox(
      height: widget.height,
      width: widget.width,
      child: ColoredBox(
        color: const Color(0x11000000),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
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
        if (bytes == null) return _loadingBox();

        return Image.memory(
          bytes,
          key: ValueKey('${widget.threadId}:${widget.attachment['id']}'),
          height: widget.height,
          width: widget.width,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _errorBox(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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
      placeholder: (_, __) => _loadingBox(),
      errorWidget: (_, __, ___) => _errorBox(retryable: false),
      imageBuilder: (context, imageProvider) {
        unawaited(FamilyChatMediaCache.trimIfNeeded());
        return Image(
          image: imageProvider,
          height: widget.height,
          width: widget.width,
          fit: widget.fit,
          gaplessPlayback: true,
        );
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
