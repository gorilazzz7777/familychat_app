import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/cache/familychat_local_cache.dart';
import '../../../../core/cache/familychat_media_cache.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../familychat/data/familychat_repository.dart';
import '../../data/chat_realtime_utils.dart';

final _webAttachmentBytesCache = <String, Uint8List>{};

String _webAttachmentCacheKey(int threadId, int attachmentId) =>
    '$threadId:$attachmentId';

/// Изображение вложения чата. На web — через API с JWT и Image.memory (браузер не шлёт Authorization в &lt;img&gt;).
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
  Uint8List? _webBytes;
  bool _webLoading = false;
  bool _webFailed = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _webLoading = true;
      _loadWebBytes();
    } else {
      _loadHeaders();
    }
  }

  @override
  void didUpdateWidget(covariant ChatNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (kIsWeb) {
      final oldId = chatAsInt(oldWidget.attachment['id']);
      final newId = chatAsInt(widget.attachment['id']);
      if (oldId != newId || oldWidget.threadId != widget.threadId) {
        _loadWebBytes();
      }
      return;
    }
    if (oldWidget.attachment['file_url'] != widget.attachment['file_url']) {
      setState(() {});
    }
  }

  Future<void> _loadHeaders() async {
    final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
    if (!mounted || token == null || token.isEmpty) return;
    setState(() => _headers = {'Authorization': 'Bearer $token'});
  }

  Future<void> _loadWebBytes() async {
    final attachmentId = chatAsInt(widget.attachment['id']);
    if (attachmentId == null) {
      setState(() {
        _webFailed = true;
        _webLoading = false;
      });
      return;
    }

    setState(() {
      _webLoading = true;
      _webFailed = false;
      _webBytes = null;
    });

    final cacheKey = _webAttachmentCacheKey(widget.threadId, attachmentId);
    final memoryCached = _webAttachmentBytesCache[cacheKey];
    if (memoryCached != null) {
      setState(() {
        _webBytes = memoryCached;
        _webFailed = false;
        _webLoading = false;
      });
      return;
    }

    try {
      final cached = await FamilyChatLocalCache.readAttachmentBytes(
        widget.threadId,
        attachmentId,
      );
      if (cached != null && cached.isNotEmpty) {
        _webAttachmentBytesCache[cacheKey] = cached;
        if (!mounted) return;
        setState(() {
          _webBytes = cached;
          _webFailed = false;
          _webLoading = false;
        });
        return;
      }

      final bytes = await ref.read(familychatRepositoryProvider).fetchChatAttachmentBytes(
            widget.threadId,
            attachmentId,
          );
      _webAttachmentBytesCache[cacheKey] = bytes;
      await FamilyChatLocalCache.saveAttachmentBytes(
        widget.threadId,
        attachmentId,
        bytes,
      );
      if (!mounted) return;
      setState(() {
        _webBytes = bytes;
        _webLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _webFailed = true;
        _webLoading = false;
        _webBytes = null;
      });
    }
  }

  String _imageUrl(FamilyChatRepository repo) {
    return widget.attachment['file_url']?.toString() ?? '';
  }

  Widget _errorBox({bool retryable = true}) {
    return GestureDetector(
      onTap: retryable && kIsWeb ? _loadWebBytes : null,
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
              if (retryable && kIsWeb) ...[
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

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      if (_webFailed) return _errorBox();
      if (_webLoading || _webBytes == null) return _loadingBox();
      return Image.memory(
        _webBytes!,
        height: widget.height,
        width: widget.width,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _errorBox(),
      );
    }

    final url = _imageUrl(ref.read(familychatRepositoryProvider));
    if (url.isEmpty) return _errorBox();

    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: _headers,
      cacheManager: FamilyChatMediaCache.preview,
      useOldImageOnUrlChange: true,
      height: widget.height,
      width: widget.width,
      fit: widget.fit,
      placeholder: (_, __) => _loadingBox(),
      errorWidget: (_, __, ___) => _errorBox(),
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
    final cacheKey = _webAttachmentCacheKey(threadId, attachmentId);
    final cached = _webAttachmentBytesCache[cacheKey];
    if (cached != null) return cached;
    final stored = await FamilyChatLocalCache.readAttachmentBytes(
      threadId,
      attachmentId,
    );
    if (stored != null && stored.isNotEmpty) {
      _webAttachmentBytesCache[cacheKey] = stored;
      return stored;
    }
    try {
      final bytes = await ref.read(familychatRepositoryProvider).fetchChatAttachmentBytes(
            threadId,
            attachmentId,
          );
      _webAttachmentBytesCache[cacheKey] = bytes;
      await FamilyChatLocalCache.saveAttachmentBytes(threadId, attachmentId, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }
