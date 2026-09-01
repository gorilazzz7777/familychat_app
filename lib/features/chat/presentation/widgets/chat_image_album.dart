import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/media/gallery_media_utils.dart';
import 'chat_media_layout.dart';
import 'chat_network_image.dart';

bool chatAttachmentLooksLikeImage(Map<String, dynamic> attachment) {
  final kind = attachment['kind']?.toString();
  if (kind == 'image') return true;
  if (kind == 'video') return false;

  final ct = attachment['content_type']?.toString().toLowerCase() ?? '';
  if (ct.startsWith('image/')) return true;

  final name = attachment['filename']?.toString().toLowerCase() ??
      attachment['file_url']?.toString().toLowerCase() ??
      '';
  if (RegExp(r'\.(gif|webp|png|jpe?g)(\?|$)').hasMatch(name)) return true;

  if (kind == 'file') return false;
  return isSafeUiPreviewBytes(attachment['local_bytes']);
}

/// Сетка фото в одном сообщении (как в мессенджерах).
class ChatImageAlbum extends StatelessWidget {
  const ChatImageAlbum({
    super.key,
    required this.threadId,
    required this.attachments,
    required this.maxWidth,
    this.onImageTap,
    this.borderRadius,
    this.uploadMessageId,
    this.onCancelUpload,
    this.messageMetadata = const {},
  });

  final int threadId;
  final List<Map<String, dynamic>> attachments;
  final double maxWidth;
  final void Function(Map<String, dynamic> attachment)? onImageTap;
  final BorderRadius? borderRadius;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;
  final Map<String, dynamic> messageMetadata;

  static const double _gap = 2;

  @override
  Widget build(BuildContext context) {
    final count = attachments.length;
    if (count == 0) return const SizedBox.shrink();

    final radius = borderRadius ?? BorderRadius.circular(10);
    final width = maxWidth > 0 ? maxWidth : 200.0;
    if (count == 1) {
      return _ChatSingleAspectThumb(
        threadId: threadId,
        attachment: attachments.first,
        maxWidth: width,
        maxHeight: chatMediaMaxThumbHeight(width),
        borderRadius: radius,
        onImageTap: onImageTap,
        uploadMessageId: uploadMessageId,
        onCancelUpload: onCancelUpload,
        messageMetadata: messageMetadata,
      );
    }

    final height = _albumHeight(count, width);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: width,
        height: height,
        child: _layout(count, width, height),
      ),
    );
  }

  double _albumHeight(int count, double width) {
    if (count == 2) return (width * 0.55).clamp(120.0, 220.0).toDouble();
    if (count == 3) return (width * 0.7).clamp(160.0, 260.0).toDouble();
    if (count == 4) return (width * 0.95).toDouble();
    return (width * 0.85).clamp(180.0, 300.0).toDouble();
  }

  Widget _layout(int count, double width, double height) {
    if (count == 2) {
      final cellW = (width - _gap) / 2;
      return Row(
        children: [
          _tile(attachments[0], width: cellW, height: height),
          const SizedBox(width: _gap),
          _tile(attachments[1], width: cellW, height: height),
        ],
      );
    }

    if (count == 3) {
      final leftW = (width - _gap) * 0.58;
      final rightW = width - _gap - leftW;
      final halfH = (height - _gap) / 2;
      return Row(
        children: [
          _tile(attachments[0], width: leftW, height: height),
          const SizedBox(width: _gap),
          SizedBox(
            width: rightW,
            height: height,
            child: Column(
              children: [
                _tile(attachments[1], width: rightW, height: halfH),
                const SizedBox(height: _gap),
                _tile(attachments[2], width: rightW, height: halfH),
              ],
            ),
          ),
        ],
      );
    }

    if (count == 4) {
      final cellW = (width - _gap) / 2;
      final cellH = (height - _gap) / 2;
      return Column(
        children: [
          Row(
            children: [
              _tile(attachments[0], width: cellW, height: cellH),
              const SizedBox(width: _gap),
              _tile(attachments[1], width: cellW, height: cellH),
            ],
          ),
          const SizedBox(height: _gap),
          Row(
            children: [
              _tile(attachments[2], width: cellW, height: cellH),
              const SizedBox(width: _gap),
              _tile(attachments[3], width: cellW, height: cellH),
            ],
          ),
        ],
      );
    }

    // 5+: 2×2, на последней плитке +N.
    final cellW = (width - _gap) / 2;
    final rowH = (height - _gap) / 2;
    final remaining = count - 4;
    return Column(
      children: [
        Row(
          children: [
            _tile(attachments[0], width: cellW, height: rowH),
            const SizedBox(width: _gap),
            _tile(attachments[1], width: cellW, height: rowH),
          ],
        ),
        const SizedBox(height: _gap),
        Row(
          children: [
            _tile(attachments[2], width: cellW, height: rowH),
            const SizedBox(width: _gap),
            _tile(
              attachments[3],
              width: cellW,
              height: rowH,
              overlayLabel: remaining > 0 ? '+$remaining' : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _tile(
    Map<String, dynamic> attachment, {
    required double width,
    required double height,
    BorderRadius? borderRadius,
    String? overlayLabel,
  }) {
    final local = attachment['local_bytes'];
    final hasLocal = isSafeUiPreviewBytes(local);
    final canOpen = onImageTap != null && !hasLocal;

    Widget image;
    if (hasLocal) {
      image = Image.memory(
        local as Uint8List,
        width: width,
        height: height,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      image = ChatNetworkImage(
        threadId: threadId,
        attachment: attachment,
        width: width,
        height: height,
        fit: BoxFit.cover,
        uploadMessageId: uploadMessageId,
        onCancelUpload: onCancelUpload,
        messageMetadata: messageMetadata,
        borderRadius: borderRadius,
      );
    }

    // Жёсткий SizedBox обязателен: StackFit.expand в Column пузыря
    // без bounded constraints роняет layout всего списка сообщений.
    Widget child = SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (overlayLabel != null)
            ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Text(
                  overlayLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius, child: child);
    }

    if (!canOpen && overlayLabel == null) return child;

    return GestureDetector(
      onTap: canOpen ? () => onImageTap!(attachment) : null,
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }
}

/// Одно фото: размер окна = пропорции кадра, без обрезки.
class _ChatSingleAspectThumb extends StatefulWidget {
  const _ChatSingleAspectThumb({
    required this.threadId,
    required this.attachment,
    required this.maxWidth,
    required this.maxHeight,
    required this.borderRadius,
    this.onImageTap,
    this.uploadMessageId,
    this.onCancelUpload,
    this.messageMetadata = const {},
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double maxWidth;
  final double maxHeight;
  final BorderRadius borderRadius;
  final void Function(Map<String, dynamic> attachment)? onImageTap;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;
  final Map<String, dynamic> messageMetadata;

  @override
  State<_ChatSingleAspectThumb> createState() => _ChatSingleAspectThumbState();
}

class _ChatSingleAspectThumbState extends State<_ChatSingleAspectThumb> {
  late double _aspect;

  @override
  void initState() {
    super.initState();
    _aspect = chatAttachmentAspectRatio(widget.attachment) ?? (4 / 3);
    _probeLocalBytes();
  }

  @override
  void didUpdateWidget(covariant _ChatSingleAspectThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment['id'] != widget.attachment['id'] ||
        oldWidget.attachment['file_url'] != widget.attachment['file_url'] ||
        oldWidget.attachment['local_bytes'] != widget.attachment['local_bytes']) {
      _aspect = chatAttachmentAspectRatio(widget.attachment) ?? _aspect;
      _probeLocalBytes();
    }
  }

  Future<void> _probeLocalBytes() async {
    final local = widget.attachment['local_bytes'];
    if (!isSafeUiPreviewBytes(local)) return;
    final size = await chatDecodeImageSize(local as Uint8List);
    if (!mounted || size == null || size.height <= 0) return;
    _applyAspect(size.width / size.height);
  }

  void _applyAspect(double next) {
    if (next <= 0 || !next.isFinite) return;
    if ((next - _aspect).abs() < 0.01) return;
    setState(() => _aspect = next);
  }

  @override
  Widget build(BuildContext context) {
    final size = chatFitMediaSize(
      aspectRatio: _aspect,
      maxWidth: widget.maxWidth,
      maxHeight: widget.maxHeight,
    );
    final local = widget.attachment['local_bytes'];
    final hasLocal = isSafeUiPreviewBytes(local);
    final canOpen = widget.onImageTap != null && !hasLocal;

    Widget image;
    if (hasLocal) {
      image = Image.memory(
        local as Uint8List,
        width: size.width,
        height: size.height,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    } else {
      image = ChatNetworkImage(
        threadId: widget.threadId,
        attachment: widget.attachment,
        width: size.width,
        height: size.height,
        fit: BoxFit.contain,
        uploadMessageId: widget.uploadMessageId,
        onCancelUpload: widget.onCancelUpload,
        messageMetadata: widget.messageMetadata,
        borderRadius: widget.borderRadius,
        onResolvedSize: (resolved) {
          if (resolved.height <= 0) return;
          _applyAspect(resolved.width / resolved.height);
        },
      );
    }

    Widget child = SizedBox(
      width: size.width,
      height: size.height,
      child: image,
    );

    child = ClipRRect(borderRadius: widget.borderRadius, child: child);

    if (!canOpen) return child;
    return GestureDetector(
      onTap: () => widget.onImageTap!(widget.attachment),
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }
}
