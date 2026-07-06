import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../profile/presentation/widgets/chat_avatar.dart';
import 'chat_network_image.dart';

class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({
    super.key,
    required this.threadId,
    required this.isMine,
    required this.body,
    required this.attachments,
    required this.createdAt,
    this.readStatus,
    this.showGroupAvatarColumn = false,
    this.showSenderAvatar = false,
    this.senderName,
    this.senderAvatarUrl,
    this.onSenderAvatarTap,
    this.compactWithNext = false,
    this.highlighted = false,
    this.onImageTap,
  });

  final int threadId;
  final bool isMine;
  final String body;
  final List<Map<String, dynamic>> attachments;
  final DateTime? createdAt;
  final String? readStatus;
  final bool showGroupAvatarColumn;
  final bool showSenderAvatar;
  final String? senderName;
  final String? senderAvatarUrl;
  final VoidCallback? onSenderAvatarTap;
  final bool compactWithNext;
  final bool highlighted;
  final void Function(Map<String, dynamic> attachment)? onImageTap;

  static const double _avatarSize = 32;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeFmt = DateFormat.Hm();
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final metaColor = isMine
        ? theme.colorScheme.onPrimary.withValues(alpha: 0.75)
        : theme.colorScheme.onSurfaceVariant;

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: highlighted
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.tertiary,
                width: 2,
              ),
            )
          : null,
      child: Material(
      color: bubbleColor,
      elevation: 0,
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(16),
        topRight: const Radius.circular(16),
        bottomLeft: Radius.circular(isMine ? 16 : 4),
        bottomRight: Radius.circular(isMine ? 4 : 16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (body.isNotEmpty)
              Text(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
              ),
            for (final a in attachments) ...[
              if (body.isNotEmpty) const SizedBox(height: 8),
              if (a['kind'] == 'image')
                GestureDetector(
                  onTap: onImageTap != null && a['local_bytes'] == null
                      ? () => onImageTap!(a)
                      : null,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _attachmentImage(a),
                  ),
                )
              else
                InkWell(
                  onTap: () {
                    final url = a['file_url']?.toString();
                    if (url != null) launchUrl(Uri.parse(url));
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.insert_drive_file_outlined, color: textColor),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          a['filename']?.toString() ?? 'Файл',
                          style: TextStyle(color: textColor),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (createdAt != null)
                  Text(
                    timeFmt.format(createdAt!.toLocal()),
                    style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
                  ),
                if (isMine && readStatus != null) ...[
                  const SizedBox(width: 4),
                  _ReadStatusIcon(status: readStatus!, color: metaColor),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
    );

    return Padding(
      padding: EdgeInsets.only(
        left: isMine ? 56 : 8,
        right: isMine ? 8 : 8,
        bottom: compactWithNext ? 1 : 6,
      ),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showGroupAvatarColumn) ...[
            SizedBox(
              width: _avatarSize,
              height: _avatarSize,
              child: showSenderAvatar
                  ? GestureDetector(
                      onTap: onSenderAvatarTap,
                      child: ChatAvatar(
                        name: senderName ?? '',
                        avatarUrl: senderAvatarUrl,
                        radius: _avatarSize / 2,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 6),
          ],
          Flexible(child: bubble),
        ],
      ),
    );
  }

  Widget _attachmentImage(Map<String, dynamic> attachment) {
    final local = attachment['local_bytes'];
    if (local is Uint8List) {
      return Image.memory(
        local,
        height: 180,
        width: double.infinity,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    return ChatNetworkImage(
      threadId: threadId,
      attachment: attachment,
      height: 180,
      width: double.infinity,
      fit: BoxFit.cover,
    );
  }
}

class _ReadStatusIcon extends StatelessWidget {
  const _ReadStatusIcon({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (status == 'sending') {
      return Semantics(
        label: 'Отправляется',
        child: Tooltip(
          message: 'Отправляется',
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: color,
            ),
          ),
        ),
      );
    }

    if (status == 'failed') {
      return Semantics(
        label: 'Не отправлено',
        child: Tooltip(
          message: 'Не отправлено',
          child: Icon(Icons.error_outline, size: 16, color: color.withValues(alpha: 0.95)),
        ),
      );
    }

    final isRead = status == 'read';
    final label = isRead ? 'Прочитано' : 'Отправлено';
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: Icon(
          isRead ? Icons.done_all : Icons.done,
          size: 16,
          color: isRead ? const Color(0xFF8FD3FF) : color,
        ),
      ),
    );
  }
}
