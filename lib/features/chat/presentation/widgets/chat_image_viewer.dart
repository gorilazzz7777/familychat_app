import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/widgets/family_app_bar.dart';
import '../../../../core/cache/familychat_media_cache.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../profile/presentation/face_tagging_sheet.dart';
import '../../../profile/presentation/widgets/photo_people_on_photo_bar.dart';
import 'chat_network_image.dart';

/// Полноэкранный просмотр изображения из чата с загрузкой/шарингом.
abstract final class ChatImageViewer {
  static Future<void> open(
    BuildContext context, {
    required String imageUrl,
    int? threadId,
    int? attachmentId,
    String? filename,
    int? messageId,
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
    this.onGoToMessage,
    this.httpHeaders,
  });

  final String imageUrl;
  final int? threadId;
  final int? attachmentId;
  final String? filename;
  final int? messageId;
  final VoidCallback? onGoToMessage;
  final Map<String, String>? httpHeaders;

  @override
  ConsumerState<_ChatImageViewerScreen> createState() => _ChatImageViewerScreenState();
}

class _ChatImageViewerScreenState extends ConsumerState<_ChatImageViewerScreen> {
  bool _downloading = false;
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

  Future<void> _initPhotos() async {
    final repo = ref.read(familychatRepositoryProvider);
    final seed = _ChatViewerPhoto(
      imageUrl: widget.imageUrl,
      threadId: widget.threadId,
      attachmentId: widget.attachmentId,
      filename: widget.filename,
      httpHeaders: widget.httpHeaders,
    );
    final media = <_ChatViewerPhoto>[seed];
    if (widget.threadId != null) {
      try {
        final threadMedia = await repo.threadMedia(widget.threadId!);
        for (final att in threadMedia) {
          final kind = att['kind']?.toString();
          if (kind != 'image') continue;
          final url = chatAttachmentImageUrl(
            repo: repo,
            threadId: widget.threadId!,
            attachment: att,
          );
          media.add(
            _ChatViewerPhoto(
              imageUrl: url,
              threadId: widget.threadId,
              attachmentId: att['id'] is int ? att['id'] as int : int.tryParse('${att['id']}'),
              filename: att['filename']?.toString(),
              attachment: att,
              httpHeaders: widget.httpHeaders,
            ),
          );
        }
      } catch (_) {
        // Fallback to single photo if media list failed.
      }
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
      return _ChatViewerPhoto(
        imageUrl: widget.imageUrl,
        threadId: widget.threadId,
        attachmentId: widget.attachmentId,
        filename: widget.filename,
        httpHeaders: widget.httpHeaders,
      );
    }
    return _photos[_index];
  }

  Future<Uint8List?> _resolveBytes(_ChatViewerPhoto photo) async {
    if (kIsWeb) {
      return chatAttachmentBytesForViewer(
        ref: ref,
        threadId: photo.threadId,
        attachmentId: photo.attachmentId,
      );
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
      final bytes = await _resolveBytes(photo);
      if (bytes == null || bytes.isEmpty) throw StateError('Пустой файл');

      final name = photo.filename?.trim().isNotEmpty == true
          ? photo.filename!.trim()
          : _guessFilename(photo.imageUrl);

      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile.fromData(bytes, name: name, mimeType: _mimeFromName(name))],
        text: name,
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

  String _guessFilename(String url) {
    final uri = Uri.tryParse(url);
    final last = uri?.pathSegments.isNotEmpty == true ? uri!.pathSegments.last : '';
    if (last.contains('.')) return last;
    return 'image.jpg';
  }

  String _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
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
          attachment: photo.attachment ?? {'id': photo.attachmentId, 'file_url': photo.imageUrl},
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
        return Image(image: imageProvider, fit: BoxFit.contain, gaplessPlayback: true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: FamilyAppBar.build(
        title: 'Фото',
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (widget.threadId != null && widget.attachmentId != null)
            IconButton(
              tooltip: 'Кто на фото',
              onPressed: () {
                final photo = _currentPhoto;
                if (photo.threadId == null || photo.attachmentId == null) return;
                FaceTaggingSheet.show(
                  context,
                  threadId: photo.threadId!,
                  attachmentId: photo.attachmentId!,
                  imageChild: _imageBody(photo),
                );
              },
              icon: const Icon(Icons.face_outlined),
            ),
          if (widget.onGoToMessage != null)
            IconButton(
              tooltip: 'Перейти к сообщению',
              onPressed: _goToMessage,
              icon: const Icon(Icons.reply_outlined),
            ),
          IconButton(
            tooltip: 'Скачать',
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: _photos.isEmpty
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemCount: _photos.length,
                    itemBuilder: (_, i) {
                      final photo = _photos[i];
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
                              child: _imageBody(photo),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_currentPhoto.attachmentId != null)
                  PhotoPeopleOnPhotoBar(
                    key: ValueKey<int>(_currentPhoto.attachmentId!),
                    attachmentId: _currentPhoto.attachmentId!,
                    threadId: _currentPhoto.threadId,
                  ),
              ],
            ),
    );
  }
}

class _ChatViewerPhoto {
  const _ChatViewerPhoto({
    required this.imageUrl,
    this.threadId,
    this.attachmentId,
    this.filename,
    this.attachment,
    this.httpHeaders,
  });

  final String imageUrl;
  final int? threadId;
  final int? attachmentId;
  final String? filename;
  final Map<String, dynamic>? attachment;
  final Map<String, String>? httpHeaders;
}
