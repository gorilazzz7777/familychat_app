import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/family_app_bar.dart';
import '../../../../core/widgets/gallery_video_player.dart';
import '../../../../core/cache/familychat_media_cache.dart';
import '../../../../core/media/gallery_media_export.dart';
import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/media_incoming_sync.dart';
import '../../../../core/media/media_local_index.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../profile/presentation/face_tagging_sheet.dart';
import '../../../profile/presentation/widgets/photo_people_on_photo_bar.dart';
import '../../../gallery/presentation/widgets/gallery_fullscreen_viewer_core.dart';
import '../../data/chat_realtime_utils.dart';
import '../chat_forward_screen.dart';
import 'chat_network_image.dart';

/// Полноэкранный просмотр фото/видео из чата.
abstract final class ChatImageViewer {
  static Future<void> open(
    BuildContext context, {
    required String imageUrl,
    int? threadId,
    int? attachmentId,
    String? filename,
    int? messageId,
    Map<String, dynamic>? attachment,
    VoidCallback? onGoToMessage,
    Map<String, String>? httpHeaders,
  }) {
    if (imageUrl.isEmpty && attachmentId == null) return Future.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ProviderScope(
          parent: ProviderScope.containerOf(context),
          child: _ChatImageViewerScreen(
            imageUrl: imageUrl,
            threadId: threadId,
            attachmentId: attachmentId,
            filename: filename,
            messageId: messageId,
            attachment: attachment,
            onGoToMessage: onGoToMessage,
            httpHeaders: httpHeaders,
          ),
        ),
      ),
    );
  }
}

class _ChatImageViewerScreen extends ConsumerStatefulWidget {
  const _ChatImageViewerScreen({
    required this.imageUrl,
    this.threadId,
    this.attachmentId,
    this.filename,
    this.messageId,
    this.attachment,
    this.onGoToMessage,
    this.httpHeaders,
  });

  final String imageUrl;
  final int? threadId;
  final int? attachmentId;
  final String? filename;
  final int? messageId;
  final Map<String, dynamic>? attachment;
  final VoidCallback? onGoToMessage;
  final Map<String, String>? httpHeaders;

  @override
  ConsumerState<_ChatImageViewerScreen> createState() =>
      _ChatImageViewerScreenState();
}

class _ChatImageViewerScreenState extends ConsumerState<_ChatImageViewerScreen> {
  bool _downloading = false;
  bool _sharing = false;
  bool _forwarding = false;
  final List<_ChatViewerPhoto> _photos = [];
  int _index = 0;
  PageController? _pageController;

  @override
  void initState() {
    super.initState();
    _initPhotos();
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  _ChatViewerPhoto _photoFromAttachment(
    Map<String, dynamic> att, {
    required String imageUrl,
    int? fallbackMessageId,
  }) {
    final copy = Map<String, dynamic>.from(att);
    MediaLocalIndex.hydrateAttachment(copy);
    return _ChatViewerPhoto(
      imageUrl: imageUrl,
      threadId: widget.threadId,
      attachmentId: chatAsInt(copy['id']) ?? widget.attachmentId,
      filename: copy['filename']?.toString() ?? widget.filename,
      messageId: chatAsInt(copy['message_id']) ?? fallbackMessageId,
      attachment: copy,
      httpHeaders: widget.httpHeaders,
    );
  }

  Future<void> _initPhotos() async {
    final repo = ref.read(familychatRepositoryProvider);
    final seedAtt = widget.attachment == null
        ? <String, dynamic>{
            if (widget.attachmentId != null) 'id': widget.attachmentId,
            if (widget.filename != null) 'filename': widget.filename,
            'file_url': widget.imageUrl,
            if (widget.messageId != null) 'message_id': widget.messageId,
            'thread_id': widget.threadId,
          }
        : Map<String, dynamic>.from(widget.attachment!);
    final seed = _photoFromAttachment(
      seedAtt,
      imageUrl: widget.imageUrl,
      fallbackMessageId: widget.messageId,
    );
    final media = <_ChatViewerPhoto>[seed];
    if (widget.threadId != null) {
      try {
        final threadMedia = await repo.threadMedia(widget.threadId!);
        for (final att in threadMedia) {
          if (!isGalleryMediaAttachment(att)) continue;
          final url = chatAttachmentImageUrl(
            repo: repo,
            threadId: widget.threadId!,
            attachment: att,
          );
          media.add(
            _photoFromAttachment(
              att,
              imageUrl: url,
            ),
          );
        }
      } catch (_) {}
    }
    final dedup = <String, _ChatViewerPhoto>{};
    for (final p in media) {
      final key = '${p.threadId}:${p.attachmentId}:${p.imageUrl}';
      dedup[key] = p;
    }
    final list = dedup.values.toList();
    var selected = 0;
    if (widget.attachmentId != null) {
      final idx = list.indexWhere((p) => p.attachmentId == widget.attachmentId);
      if (idx >= 0) selected = idx;
    } else if (widget.imageUrl.isNotEmpty) {
      final idx = list.indexWhere((p) => p.imageUrl == widget.imageUrl);
      if (idx >= 0) selected = idx;
    }
    if (!mounted) return;
    setState(() {
      _photos
        ..clear()
        ..addAll(list.isEmpty ? [seed] : list);
      _index = selected.clamp(0, _photos.length - 1);
      _pageController = PageController(initialPage: _index);
    });
  }

  _ChatViewerPhoto get _currentPhoto {
    if (_photos.isEmpty) {
      return _photoFromAttachment(
        widget.attachment ??
            {
              if (widget.attachmentId != null) 'id': widget.attachmentId,
              if (widget.filename != null) 'filename': widget.filename,
              'file_url': widget.imageUrl,
              if (widget.messageId != null) 'message_id': widget.messageId,
            },
        imageUrl: widget.imageUrl,
        fallbackMessageId: widget.messageId,
      );
    }
    return _photos[_index];
  }

  Map<String, dynamic> _attachmentMap(_ChatViewerPhoto photo) {
    final att = photo.attachment == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(photo.attachment!);
    att['id'] ??= photo.attachmentId;
    att['filename'] ??= photo.filename ?? _guessFilename(photo);
    att['file_url'] ??= photo.imageUrl;
    att['kind'] ??= photo.isVideo ? 'video' : 'image';
    att['thread_id'] ??= photo.threadId;
    att['message_id'] ??= photo.messageId;
    return att;
  }

  Future<Uint8List?> _resolveBytes(_ChatViewerPhoto photo) async {
    if (kIsWeb) {
      return chatAttachmentBytesForViewer(
        ref: ref,
        threadId: photo.threadId,
        attachmentId: photo.attachmentId,
      );
    }
    if (photo.threadId != null && photo.attachmentId != null) {
      try {
        return await ref
            .read(familychatRepositoryProvider)
            .fetchChatAttachmentBytes(photo.threadId!, photo.attachmentId!);
      } catch (_) {}
    }
    final response = await ref.read(apiClientProvider).dio.get<List<int>>(
          photo.imageUrl,
          options: Options(responseType: ResponseType.bytes),
        );
    final data = response.data;
    if (data == null || data.isEmpty) return null;
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  Future<void> _download() async {
    if (_downloading) return;
    final photo = _currentPhoto;
    setState(() => _downloading = true);
    try {
      await MediaIncomingSync.saveByUserDownload(
        _attachmentMap(photo),
        fetchBytes: photo.threadId == null || photo.attachmentId == null
            ? null
            : () async {
                final bytes = await _resolveBytes(photo);
                if (bytes == null || bytes.isEmpty) {
                  throw StateError('Пустой файл');
                }
                return bytes;
              },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Сохранено в галерею («${GalleryMediaExport.appAlbumName}»)',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось скачать: $e')),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    final photo = _currentPhoto;
    setState(() => _sharing = true);
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin =
          box == null ? null : box.localToGlobal(Offset.zero) & box.size;
      await GalleryMediaExport.shareAttachments(
        attachments: [_attachmentMap(photo)],
        fetchBytes: photo.threadId == null || photo.attachmentId == null
            ? null
            : (_) async {
                final bytes = await _resolveBytes(photo);
                if (bytes == null || bytes.isEmpty) {
                  throw StateError('Пустой файл');
                }
                return bytes;
              },
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось поделиться: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _forward() async {
    if (_forwarding) return;
    final photo = _currentPhoto;
    final threadId = photo.threadId ?? widget.threadId;
    final messageId = photo.messageId ?? widget.messageId;
    if (threadId == null || messageId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось переслать')),
      );
      return;
    }
    setState(() => _forwarding = true);
    try {
      final targets = await ChatForwardScreen.open(
        context,
        sourceThreadId: threadId,
        messageIds: [messageId],
      );
      if (!mounted) return;
      if (targets != null && targets.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Переслано')),
        );
      }
    } finally {
      if (mounted) setState(() => _forwarding = false);
    }
  }

  String _guessFilename(_ChatViewerPhoto photo) {
    final uri = Uri.tryParse(photo.imageUrl);
    final last =
        uri?.pathSegments.isNotEmpty == true ? uri!.pathSegments.last : '';
    if (last.contains('.')) return last;
    return photo.isVideo ? 'video.mp4' : 'image.jpg';
  }

  void _goToMessage() {
    Navigator.of(context).pop();
    widget.onGoToMessage?.call();
  }

  Widget _imageBody(_ChatViewerPhoto photo) {
    if (kIsWeb) {
      if (photo.threadId != null && photo.attachmentId != null) {
        return ChatNetworkImage(
          threadId: photo.threadId!,
          attachment: photo.attachment ??
              {'id': photo.attachmentId, 'file_url': photo.imageUrl},
          fit: BoxFit.contain,
        );
      }
    }

    return CachedNetworkImage(
      imageUrl: photo.imageUrl,
      httpHeaders: photo.httpHeaders,
      cacheManager: FamilyChatMediaCache.fullscreen,
      useOldImageOnUrlChange: true,
      fit: BoxFit.contain,
      imageBuilder: (context, imageProvider) {
        unawaited(FamilyChatMediaCache.trimIfNeeded());
        return Image(
          image: imageProvider,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
      },
    );
  }

  Widget _mediaBody(_ChatViewerPhoto photo, {required bool autoplay}) {
    if (photo.isVideo) {
      final local = galleryLocalDevicePath(photo.attachment ?? const {});
      return GalleryVideoPlayer(
        url: photo.imageUrl,
        localPath: local.isEmpty ? null : local,
        httpHeaders: photo.httpHeaders,
        fit: BoxFit.contain,
        autoplay: autoplay,
      );
    }
    return _imageBody(photo);
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photos.isEmpty ? null : _currentPhoto;
    final isVideo = photo?.isVideo == true;
    final canForward =
        (photo?.threadId ?? widget.threadId) != null &&
            (photo?.messageId ?? widget.messageId) != null;
    final canFaceTag = !isVideo &&
        (photo?.threadId ?? widget.threadId) != null &&
        (photo?.attachmentId ?? widget.attachmentId) != null;

    if (_photos.isEmpty || _pageController == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: FamilyAppBar.build(
          title: 'Фото',
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return GalleryFullscreenViewerCore(
      pageController: _pageController!,
      itemCount: _photos.length,
      title: isVideo ? 'Видео' : 'Фото',
      onPageChanged: (i) => setState(() => _index = i),
      actions: [
        IconButton(
          tooltip: 'Поделиться',
          onPressed: _sharing ? null : _share,
          icon: _sharing
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.share_outlined),
        ),
        if (canForward)
          IconButton(
            tooltip: 'Переслать',
            onPressed: _forwarding ? null : _forward,
            icon: const Icon(Icons.forward_outlined),
          ),
        IconButton(
          tooltip: 'Скачать',
          onPressed: _downloading ? null : _download,
          icon: _downloading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download_outlined),
        ),
        if (canFaceTag || widget.onGoToMessage != null)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'faces':
                  final current = _currentPhoto;
                  if (current.threadId == null ||
                      current.attachmentId == null) {
                    return;
                  }
                  FaceTaggingSheet.show(
                    context,
                    threadId: current.threadId!,
                    attachmentId: current.attachmentId!,
                    imageChild: _imageBody(current),
                  );
                case 'goto':
                  _goToMessage();
              }
            },
            itemBuilder: (context) => [
              if (canFaceTag)
                const PopupMenuItem(
                  value: 'faces',
                  child: Text('Кто на фото'),
                ),
              if (widget.onGoToMessage != null)
                const PopupMenuItem(
                  value: 'goto',
                  child: Text('Перейти к сообщению'),
                ),
            ],
          ),
      ],
      pageBuilder: (_, i) {
        final item = _photos[i];
        if (item.isVideo) {
          return _mediaBody(item, autoplay: i == _index);
        }
        return LayoutBuilder(
          builder: (context, constraints) => Center(
            child: InteractiveViewer(
              minScale: 0.2,
              maxScale: 5,
              constrained: false,
              clipBehavior: Clip.none,
              child: SizedBox(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                child: _mediaBody(item, autoplay: i == _index),
              ),
            ),
          ),
        );
      },
      bottomSlots: [
        if (_currentPhoto.attachmentId != null && !_currentPhoto.isVideo)
          PhotoPeopleOnPhotoBar(
            key: ValueKey<int>(_currentPhoto.attachmentId!),
            attachmentId: _currentPhoto.attachmentId!,
            threadId: _currentPhoto.threadId,
          ),
      ],
    );
  }
}

class _ChatViewerPhoto {
  const _ChatViewerPhoto({
    required this.imageUrl,
    this.threadId,
    this.attachmentId,
    this.filename,
    this.messageId,
    this.attachment,
    this.httpHeaders,
  });

  final String imageUrl;
  final int? threadId;
  final int? attachmentId;
  final String? filename;
  final int? messageId;
  final Map<String, dynamic>? attachment;
  final Map<String, String>? httpHeaders;

  bool get isVideo =>
      isVideoAttachment(attachment ?? {'filename': filename, 'file_url': imageUrl});
}
