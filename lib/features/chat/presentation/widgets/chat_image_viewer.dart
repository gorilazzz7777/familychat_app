import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../profile/presentation/face_tagging_sheet.dart';
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
  Uint8List? _webBytes;
  bool _webLoading = false;
  bool _webFailed = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _loadWebBytes();
    }
  }

  Future<void> _loadWebBytes() async {
    setState(() {
      _webLoading = true;
      _webFailed = false;
    });
    final bytes = await chatAttachmentBytesForViewer(
      ref: ref,
      threadId: widget.threadId,
      attachmentId: widget.attachmentId,
    );
    if (!mounted) return;
    setState(() {
      _webBytes = bytes;
      _webLoading = false;
      _webFailed = bytes == null;
    });
  }

  Future<Uint8List?> _resolveBytes() async {
    if (kIsWeb) {
      if (_webBytes != null) return _webBytes;
      return chatAttachmentBytesForViewer(
        ref: ref,
        threadId: widget.threadId,
        attachmentId: widget.attachmentId,
      );
    }
    final response = await ref.read(apiClientProvider).dio.get<List<int>>(
          widget.imageUrl,
          options: Options(responseType: ResponseType.bytes),
        );
    final data = response.data;
    if (data == null || data.isEmpty) return null;
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final bytes = await _resolveBytes();
      if (bytes == null || bytes.isEmpty) throw StateError('Пустой файл');

      final name = widget.filename?.trim().isNotEmpty == true
          ? widget.filename!.trim()
          : _guessFilename(widget.imageUrl);

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

  Widget _imageBody() {
    if (kIsWeb) {
      if (_webLoading) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      }
      if (_webFailed || _webBytes == null) {
        return const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48);
      }
      return Image.memory(
        _webBytes!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }

    return CachedNetworkImage(
      imageUrl: widget.imageUrl,
      httpHeaders: widget.httpHeaders,
      fit: BoxFit.contain,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (widget.threadId != null && widget.attachmentId != null)
            IconButton(
              tooltip: 'Кто на фото',
              onPressed: () {
                FaceTaggingSheet.show(
                  context,
                  threadId: widget.threadId!,
                  attachmentId: widget.attachmentId!,
                  imageChild: _imageBody(),
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
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: _imageBody(),
        ),
      ),
    );
  }
}
