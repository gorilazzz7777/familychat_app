import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Полноэкранный просмотр изображения из чата с загрузкой/шарингом.
abstract final class ChatImageViewer {
  static Future<void> open(
    BuildContext context, {
    required String imageUrl,
    String? filename,
    int? messageId,
    VoidCallback? onGoToMessage,
    Map<String, String>? httpHeaders,
  }) {
    if (imageUrl.isEmpty) return Future.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ChatImageViewerScreen(
          imageUrl: imageUrl,
          filename: filename,
          messageId: messageId,
          onGoToMessage: onGoToMessage,
          httpHeaders: httpHeaders,
        ),
      ),
    );
  }
}

class _ChatImageViewerScreen extends StatefulWidget {
  const _ChatImageViewerScreen({
    required this.imageUrl,
    this.filename,
    this.messageId,
    this.onGoToMessage,
    this.httpHeaders,
  });

  final String imageUrl;
  final String? filename;
  final int? messageId;
  final VoidCallback? onGoToMessage;
  final Map<String, String>? httpHeaders;

  @override
  State<_ChatImageViewerScreen> createState() => _ChatImageViewerScreenState();
}

class _ChatImageViewerScreenState extends State<_ChatImageViewerScreen> {
  bool _downloading = false;

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final response = await Dio().get<List<int>>(
        widget.imageUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: widget.httpHeaders,
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) throw StateError('Пустой файл');

      final name = widget.filename?.trim().isNotEmpty == true
          ? widget.filename!.trim()
          : _guessFilename(widget.imageUrl);

      final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile.fromData(data, name: name, mimeType: _mimeFromName(name))],
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
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
          child: CachedNetworkImage(
            imageUrl: widget.imageUrl,
            httpHeaders: widget.httpHeaders,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
