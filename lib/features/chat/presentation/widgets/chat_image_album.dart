import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'chat_network_image.dart';

bool chatAttachmentLooksLikeImage(Map<String, dynamic> attachment) {
  final kind = attachment['kind']?.toString();
  if (kind == 'image') return true;
  if (kind == 'video' || kind == 'file') return false;
  final local = attachment['local_bytes'];
  return local is Uint8List && local.isNotEmpty;
}

/// Сетка фото в одном сообщении (как в мессенджерах).
class ChatImageAlbum extends StatelessWidget {
  const ChatImageAlbum({
    super.key,
    required this.threadId,
    required this.attachments,
    required this.maxWidth,
    this.onImageTap,
  });

  final int threadId;
  final List<Map<String, dynamic>> attachments;
  final double maxWidth;
  final void Function(Map<String, dynamic> attachment)? onImageTap;

  static const double _gap = 2;

  @override
  Widget build(BuildContext context) {
    final count = attachments.length;
    if (count == 0) return const SizedBox.shrink();

    final width = maxWidth > 0 ? maxWidth : 200.0;
    if (count == 1) {
      final height = _singleHeight(width);
      return _tile(
        attachments.first,
        width: width,
        height: height,
        borderRadius: BorderRadius.circular(8),
      );
    }

    final height = _albumHeight(count, width);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: width,
        height: height,
        child: _layout(count, width, height),
      ),
    );
  }

  double _singleHeight(double width) =>
      (width * 0.75).clamp(140.0, 280.0).toDouble();

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
    final hasLocal = local is Uint8List && local.isNotEmpty;
    final canOpen = onImageTap != null && !hasLocal;

    Widget image;
    if (hasLocal) {
      image = Image.memory(
        local,
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
