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
import '../../../../core/network/chat_network_link.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/settings/app_settings_controller.dart';
import '../../../../core/widgets/web_image_cache_registry.dart';
import '../../../familychat/data/familychat_repository.dart';
import '../../data/chat_attachment_download_manager.dart';
import '../../data/chat_media_auto_download.dart';
import '../../data/chat_media_display_policy.dart';
import '../../data/chat_media_providers.dart';
import '../../data/chat_realtime_utils.dart';
import 'chat_attachment_thumb.dart';
import 'chat_media_transfer_overlay.dart';

final _attachmentBytesCache = <String, Uint8List>{};

String _attachmentCacheKey(int threadId, int attachmentId) =>
    '$threadId:$attachmentId';

/// Изображение вложения чата.
///
/// Превью сразу; полный файл — через [ChatAttachmentDownloadManager]
/// (авто или по кнопке «Загрузить»), с % и отменой.
///
/// Медиа старше [ChatMediaDisplayPolicy.deferredFullMediaAge] не декодятся
/// в пузыре, пока пользователь не нажмёт «Загрузить» (кэш на диске не чистим).
class ChatNetworkImage extends ConsumerStatefulWidget {
  const ChatNetworkImage({
    super.key,
    required this.threadId,
    required this.attachment,
    this.height,
    this.width,
    this.fit = BoxFit.cover,
    this.onResolvedSize,
    this.uploadMessageId,
    this.onCancelUpload,
    this.messageMetadata = const {},
    this.messageCreatedAt,
    this.borderRadius,
    this.showTransferOverlay = true,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double? height;
  final double? width;
  final BoxFit fit;
  final ValueChanged<Size>? onResolvedSize;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;
  final Map<String, dynamic> messageMetadata;
  final DateTime? messageCreatedAt;
  final BorderRadius? borderRadius;
  final bool showTransferOverlay;

  @override
  ConsumerState<ChatNetworkImage> createState() => _ChatNetworkImageState();
}

class _ChatNetworkImageState extends ConsumerState<ChatNetworkImage> {
  Map<String, String>? _headers;
  bool _sizeReported = false;
  bool _sizeListenAttached = false;
  bool _urlLoadAllowed = false;

  int? get _attachmentId => chatAsInt(widget.attachment['id']);

  bool get _deferFullDecode => ChatMediaDisplayPolicy.shouldDeferFullDecode(
        threadId: widget.threadId,
        attachmentId: _attachmentId,
        messageCreatedAt: widget.messageCreatedAt,
      );

  @override
  void initState() {
    super.initState();
    _urlLoadAllowed = !_deferFullDecode && _shouldAutoLoadUrl();
    if (_useBytesPath) {
      _scheduleAutoDownload();
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
    final ageChanged =
        oldWidget.messageCreatedAt != widget.messageCreatedAt;
    if (oldId != newId ||
        oldWidget.threadId != widget.threadId ||
        urlChanged ||
        ageChanged) {
      _sizeReported = false;
      _sizeListenAttached = false;
      _urlLoadAllowed = !_deferFullDecode && _shouldAutoLoadUrl();
      if (_useBytesPath) {
        _scheduleAutoDownload();
      } else {
        _loadHeaders();
      }
    }
  }

  bool _shouldAutoLoadUrl() {
    final settings = ref.read(appSettingsProvider);
    final network = ref.read(chatNetworkLinkProvider).value ??
        ChatNetworkLinkKind.unknown;
    return ChatMediaAutoDownloadPolicy.shouldAutoDownload(
      settings: settings,
      network: network,
      attachment: widget.attachment,
      messageMetadata: widget.messageMetadata,
    );
  }

  void _scheduleAutoDownload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_deferFullDecode) return;
      final attachmentId = _attachmentId;
      if (attachmentId == null || attachmentId <= 0) return;
      final settings = ref.read(appSettingsProvider);
      final network = ref.read(chatNetworkLinkProvider).value ??
          ChatNetworkLinkKind.unknown;
      unawaited(
        ref.read(chatAttachmentDownloadManagerProvider).maybeAutoDownload(
              threadId: widget.threadId,
              attachment: widget.attachment,
              settings: settings,
              network: network,
              messageMetadata: widget.messageMetadata,
            ),
      );
    });
  }

  Future<void> _loadHeaders() async {
    final token = await ref.read(apiClientProvider).tokenStorage.readAccess();
    if (!mounted || token == null || token.isEmpty) return;
    setState(() => _headers = {'Authorization': 'Bearer $token'});
  }

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

  int? get _memCacheWidth =>
      ChatMediaDisplayPolicy.memCacheWidthPx(context, widget.width);

  ImageProvider _sizedProvider(ImageProvider provider) {
    final w = _memCacheWidth;
    if (w == null) return provider;
    // Width-only keeps aspect; height would force-crop decode.
    return ResizeImage(provider, width: w);
  }

  Widget _sizedImage({
    required ImageProvider provider,
    Key? key,
    ImageErrorWidgetBuilder? errorBuilder,
  }) {
    final sized = _sizedProvider(provider);
    _listenProviderSize(sized);
    return Image(
      key: key,
      image: sized,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      errorBuilder: errorBuilder ?? (_, __, ___) => _thumbPlaceholder(),
    );
  }

  String? get _registryKey {
    final attachmentId = _attachmentId;
    if (attachmentId == null) return null;
    return WebImageCacheRegistry.attachmentKey(widget.threadId, attachmentId);
  }

  bool get _useBytesPath {
    return _imageUrl(ref.read(familychatRepositoryProvider)).isEmpty;
  }

  bool _isFullMediaDisplayed() {
    if (_deferFullDecode) return false;
    MediaLocalIndex.hydrateAttachment(widget.attachment);
    final localPath = galleryLocalDevicePath(widget.attachment);
    if (localDeviceFileExists(localPath)) return true;
    if (isSafeUiPreviewBytes(widget.attachment['local_bytes'])) return true;
    if (_cachedBytes() != null) return true;
    if (!_useBytesPath && _urlLoadAllowed) return true;
    return false;
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

  Future<void> _manualDownload() async {
    final attachmentId = _attachmentId;
    if (attachmentId == null) return;

    ChatMediaDisplayPolicy.markExpanded(widget.threadId, attachmentId);

    if (!_useBytesPath) {
      if (!_urlLoadAllowed) {
        setState(() => _urlLoadAllowed = true);
      } else {
        setState(() {});
      }
      return;
    }
    setState(() {});
    final bytes = await ref.read(chatAttachmentDownloadManagerProvider).startDownload(
          threadId: widget.threadId,
          attachmentId: attachmentId,
          manual: true,
        );
    if (!mounted || bytes == null) return;
    final cacheKey = _attachmentCacheKey(widget.threadId, attachmentId);
    _attachmentBytesCache[cacheKey] = bytes;
    final key = _registryKey;
    if (key != null) WebImageCacheRegistry.notifyUpdated(key);
    setState(() {});
  }

  String _imageUrl(FamilyChatRepository repo) {
    return chatAttachmentImageUrl(
      repo: repo,
      threadId: widget.threadId,
      attachment: widget.attachment,
    );
  }

  Map<String, String>? get _networkHeaders {
    if (_attachmentId == null) return null;
    final url = _imageUrl(ref.read(familychatRepositoryProvider));
    if (url.isEmpty) return _headers;
    // CDN-превью (Klipy GIF до сохранения на сервере) — без Bearer.
    if (!_looksLikeAuthenticatedAttachmentUrl(url)) return null;
    return _headers;
  }

  bool _looksLikeAuthenticatedAttachmentUrl(String url) {
    return url.contains('/attachments/') && url.contains('/content');
  }

  Widget _thumbPlaceholder({bool lightOnly = false}) {
    return ChatAttachmentThumb(
      attachment: widget.attachment,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      borderRadius: widget.borderRadius,
      lightOnly: lightOnly || _deferFullDecode,
    );
  }

  Widget _wrapOverlay(Widget child) {
    if (!widget.showTransferOverlay) return child;
    return ChatMediaTransferOverlay(
      threadId: widget.threadId,
      attachment: widget.attachment,
      uploadMessageId: widget.uploadMessageId,
      onCancelUpload: widget.onCancelUpload,
      onDownloadTap: _manualDownload,
      borderRadius: widget.borderRadius,
      showManualDownload: !_isFullMediaDisplayed(),
      showWhenDownloading: _useBytesPath || _deferFullDecode,
      child: child,
    );
  }

  Widget _buildBytesImage() {
    final registryKey = _registryKey;
    if (registryKey == null) return _thumbPlaceholder();

    return ValueListenableBuilder<int>(
      valueListenable: WebImageCacheRegistry.listenable(registryKey),
      builder: (context, _, __) {
        final bytes = _cachedBytes();
        if (bytes == null) return _wrapOverlay(_thumbPlaceholder());

        return _wrapOverlay(
          _sizedImage(
            provider: MemoryImage(bytes),
            key: ValueKey('${widget.threadId}:${widget.attachment['id']}'),
          ),
        );
      },
    );
  }

  Widget _buildUrlImage(String url) {
    if (!_urlLoadAllowed) {
      return _wrapOverlay(_thumbPlaceholder());
    }

    if (_looksLikeAuthenticatedAttachmentUrl(url) &&
        (_headers == null || _headers!.isEmpty)) {
      unawaited(_loadHeaders());
      return _wrapOverlay(_thumbPlaceholder());
    }

    return _wrapOverlay(
      CachedNetworkImage(
        key: ValueKey('net:$url'),
        imageUrl: url,
        httpHeaders: _networkHeaders,
        cacheManager: FamilyChatMediaCache.preview,
        useOldImageOnUrlChange: true,
        height: widget.height,
        width: widget.width,
        fit: widget.fit,
        memCacheWidth: _memCacheWidth,
        memCacheHeight: null,
        progressIndicatorBuilder: (context, _, progress) {
          final total = progress.totalSize;
          final downloaded = progress.downloaded;
          final value = total != null && total > 0 ? downloaded / total : null;
          if (value == null) {
            return _wrapOverlay(_thumbPlaceholder());
          }
          return _wrapOverlay(
            Stack(
              fit: StackFit.expand,
              children: [
                _thumbPlaceholder(),
                ColoredBox(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: Center(
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: CircularProgressIndicator(
                        value: value,
                        strokeWidth: 3,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        errorWidget: (_, __, ___) => _wrapOverlay(_thumbPlaceholder()),
        imageBuilder: (context, imageProvider) {
          unawaited(FamilyChatMediaCache.trimIfNeeded());
          // Provider already constrained via memCacheWidth on CachedNetworkImage.
          _listenProviderSize(imageProvider);
          return Image(
            image: imageProvider,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: true,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatAttachmentDownloadManagerProvider, (_, __) {
      if (mounted) setState(() {});
    });
    ref.listen(chatNetworkLinkProvider, (_, __) {
      if (mounted) _scheduleAutoDownload();
    });
    ref.listen(appSettingsProvider, (_, __) {
      if (!mounted) return;
      if (_deferFullDecode) return;
      final allowed = _shouldAutoLoadUrl();
      if (allowed != _urlLoadAllowed) {
        setState(() => _urlLoadAllowed = allowed);
      }
    });

    // Old media: light stub + Load — skip full local / network decode.
    if (_deferFullDecode) {
      return _wrapOverlay(_thumbPlaceholder(lightOnly: true));
    }

    MediaLocalIndex.hydrateAttachment(widget.attachment);
    final localPath = galleryLocalDevicePath(widget.attachment);
    if (localDeviceFileExists(localPath)) {
      final localImage = localDeviceFileImage(
        path: localPath,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: _memCacheWidth,
        cacheHeight: null,
        error: _thumbPlaceholder(),
      );
      if (localImage is Image) {
        _listenProviderSize(localImage.image);
      }
      return _wrapOverlay(localImage);
    }

    final local = widget.attachment['local_bytes'];
    if (isSafeUiPreviewBytes(local)) {
      return _wrapOverlay(
        _sizedImage(
          provider: MemoryImage(local as Uint8List),
        ),
      );
    }

    if (_useBytesPath) {
      return _buildBytesImage();
    }

    final url = _imageUrl(ref.read(familychatRepositoryProvider));
    if (url.isEmpty) return _wrapOverlay(_thumbPlaceholder());

    return _buildUrlImage(url);
  }
}

String chatAttachmentImageUrl({
  required FamilyChatRepository repo,
  required int threadId,
  required Map<String, dynamic> attachment,
}) {
  final attachmentId = chatAsInt(attachment['id']);
  final fileUrl = attachment['file_url']?.toString().trim() ?? '';
  final altUrl = attachment['url']?.toString().trim() ?? '';

  // Как на web: сохранённые вложения — через API content/ + Bearer.
  if (attachmentId != null && attachmentId > 0) {
    return repo.chatAttachmentContentUrl(threadId, attachmentId);
  }

  if (fileUrl.isNotEmpty) return fileUrl;
  return altUrl;
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
