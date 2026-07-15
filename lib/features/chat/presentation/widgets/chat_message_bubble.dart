import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/widgets/gallery_video_player.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';
import '../../data/chat_location_utils.dart';
import '../../data/chat_voice_utils.dart';
import 'chat_location_preview.dart';
import 'chat_message_quote.dart';
import 'chat_message_reactions.dart';
import 'chat_message_read_status_icon.dart';
import 'chat_message_tap_target.dart';
import 'chat_mention_text.dart';
import 'chat_network_image.dart';
import 'chat_swipe_to_reply.dart';
import 'chat_voice_message_player.dart';

class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({
    super.key,
    required this.threadId,
    required this.isMine,
    required this.body,
    required this.attachments,
    required this.createdAt,
    this.readStatus,
    this.replyTo,
    this.forward,
    this.reactions = const [],
    this.showGroupAvatarColumn = false,
    this.showSenderAvatar = false,
    this.senderName,
    this.senderAvatarUrl,
    this.onSenderAvatarTap,
    this.compactWithNext = false,
    this.highlighted = false,
    this.selectionMode = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onImageTap,
    this.onReplyTap,
    this.onSwipeReply,
    this.onReactionTap,
    this.isGroupLike = false,
    this.mentions = const [],
    this.scheduledAt,
    this.location,
    this.messageMetadata = const {},
    this.canToggleVoiceTranscript = false,
  });

  final int threadId;
  final bool isMine;
  final String body;
  final List<Map<String, dynamic>> attachments;
  final DateTime? createdAt;
  final String? readStatus;
  final Map<String, dynamic>? replyTo;
  final Map<String, dynamic>? forward;
  final List<Map<String, dynamic>> reactions;
  final bool showGroupAvatarColumn;
  final bool showSenderAvatar;
  final String? senderName;
  final String? senderAvatarUrl;
  final VoidCallback? onSenderAvatarTap;
  final bool compactWithNext;
  final bool highlighted;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(Map<String, dynamic> attachment)? onImageTap;
  final VoidCallback? onReplyTap;
  /// Свайп влево — то же, что «Ответить» в меню.
  final VoidCallback? onSwipeReply;
  final void Function(String emoji)? onReactionTap;
  final bool isGroupLike;
  final List<Map<String, dynamic>> mentions;
  final DateTime? scheduledAt;
  final ChatLocationPoint? location;
  final Map<String, dynamic> messageMetadata;
  final bool canToggleVoiceTranscript;

  static const double _avatarSize = 32;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeFmt = DateFormat.Hm();
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxBubbleWidth = screenWidth * 0.78;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final metaColor = isMine
        ? theme.colorScheme.onPrimary.withValues(alpha: 0.75)
        : theme.colorScheme.onSurfaceVariant;
    final quoteAccent = isMine ? const Color(0xFF8FD3FF) : theme.colorScheme.primary;

    Widget bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlighted
              ? theme.colorScheme.tertiary
              : selected
                  ? theme.colorScheme.tertiary
                  : Colors.transparent,
          width: highlighted || selected ? 2 : 0,
        ),
      ),
      child: Material(
        color: bubbleColor,
        elevation: 0,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMine ? 16 : 4),
          bottomRight: Radius.circular(isMine ? 4 : 16),
        ),
        child: ChatMessageTapTarget(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (forward != null)
                  _buildForwardQuote(forward!, quoteAccent, textColor),
                if (replyTo != null)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onReplyTap,
                    child: _buildReplyQuote(replyTo!, quoteAccent, textColor),
                  ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_showBody(body, forward))
                      ChatMentionText(
                        body: body,
                        mentions: mentions,
                        style: theme.textTheme.bodyMedium
                                ?.copyWith(color: textColor) ??
                            TextStyle(color: textColor),
                        mentionStyle:
                            (theme.textTheme.bodyMedium ?? const TextStyle())
                                .copyWith(
                          color: isMine
                              ? const Color(0xFF8FD3FF)
                              : theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                        linkStyle:
                            (theme.textTheme.bodyMedium ?? const TextStyle())
                                .copyWith(
                          color: isMine
                              ? const Color(0xFF8FD3FF)
                              : theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    if (location != null) ...[
                      if (_showBody(body, forward)) const SizedBox(height: 8),
                      ChatLocationPreview(
                        location: location!,
                        isMine: isMine,
                        maxWidth: maxBubbleWidth - 24,
                      ),
                    ],
                    for (final a in attachments) ...[
                      if (body.isNotEmpty || location != null)
                        const SizedBox(height: 8),
                      if (isVoiceAttachment(a, messageMetadata: messageMetadata))
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 180),
                          child: ChatVoiceMessagePlayer(
                            threadId: threadId,
                            attachment: a,
                            isMine: isMine,
                            durationMs: voiceDurationMsForAttachment(
                              a,
                              messageMetadata: messageMetadata,
                            ),
                            transcript: () {
                              final voice = messageMetadata['voice'];
                              if (voice is! Map) return null;
                              final text = voice['transcript']?.toString().trim();
                              if (text == null || text.isEmpty) return null;
                              return text;
                            }(),
                            canToggleTranscript: canToggleVoiceTranscript,
                            textColor: textColor,
                            metaColor: metaColor,
                          ),
                        )
                      else if (a['kind'] == 'image' ||
                          (a['local_bytes'] is Uint8List &&
                              a['kind'] != 'video' &&
                              a['kind'] != 'file'))
                        GestureDetector(
                          onTap: onImageTap != null && a['local_bytes'] == null
                              ? () => onImageTap!(a)
                              : null,
                          behavior: HitTestBehavior.opaque,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: _attachmentImage(a, maxBubbleWidth - 24),
                          ),
                        )
                      else if (a['kind'] == 'video' || isVideoAttachment(a))
                        _ChatVideoAttachmentPreview(
                          threadId: threadId,
                          attachment: a,
                          maxWidth: maxBubbleWidth - 24,
                          onOpen: onImageTap != null
                              ? () => onImageTap!(a)
                              : null,
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
                              Icon(Icons.insert_drive_file_outlined,
                                  color: textColor),
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
                        if (scheduledAt != null) ...[
                          Icon(Icons.schedule, size: 13, color: metaColor),
                          const SizedBox(width: 4),
                          Text(
                            timeFmt.format(scheduledAt!.toLocal()),
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: metaColor),
                          ),
                        ] else if (createdAt != null)
                          Text(
                            timeFmt.format(createdAt!.toLocal()),
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: metaColor),
                          ),
                        if (isMine && readStatus != null) ...[
                          const SizedBox(width: 4),
                          ChatMessageReadStatusIcon(
                            status: readStatus!,
                            color: metaColor,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return ChatSwipeToReply(
      onReply: selectionMode ? null : onSwipeReply,
      child: Padding(
        padding: EdgeInsets.only(
          left: 8,
          right: 8,
          bottom: reactions.isNotEmpty
              ? (compactWithNext ? 14 : 18)
              : (compactWithNext ? 1 : 6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment:
              isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (selectionMode)
              Padding(
                padding: EdgeInsets.only(right: isMine ? 6 : 6),
                child: Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
              ),
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
            Flexible(
              child: Align(
                alignment:
                    isMine ? Alignment.centerRight : Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      bubble,
                      if (reactions.isNotEmpty)
                        Positioned(
                          left: isMine ? 20 : 6,
                          right: isMine ? 6 : 20,
                          // Наезжает на нижний край пузыря ~на половину чипа.
                          bottom: -11,
                          child: Align(
                            alignment: isMine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: ChatMessageReactionsRow(
                              reactions: reactions,
                              alignEnd: isMine,
                              onReactionTap: onReactionTap,
                              overlapStyle: true,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _showBody(String body, Map<String, dynamic>? forward) {
    if (body.isEmpty) return false;
    if (forward == null) return true;
    final original = forward['original_body']?.toString() ?? '';
    return body.trim() != original.trim();
  }

  Widget _buildReplyQuote(
    Map<String, dynamic> reply,
    Color accent,
    Color textColor,
  ) {
    return ChatMessageQuote(
      title: reply['sender_name']?.toString() ?? 'Сообщение',
      body: reply['body']?.toString() ?? '',
      accentColor: accent,
      textColor: textColor,
    );
  }

  Widget _buildForwardQuote(
    Map<String, dynamic> fwd,
    Color accent,
    Color textColor,
  ) {
    final originalSender = fwd['original_sender_name']?.toString() ?? '';
    final forwardedBy = fwd['forwarded_by_name']?.toString() ?? '';
    final threadTitle = fwd['original_thread_title']?.toString() ?? '';
    final originalBody = fwd['original_body']?.toString() ?? '';

    String title;
    String? subtitle;
    if (isGroupLike && forwardedBy.isNotEmpty) {
      title = 'Переслано $forwardedBy';
      subtitle = originalSender.isNotEmpty ? 'от $originalSender' : null;
    } else if (originalSender.isNotEmpty) {
      title = 'Переслано от $originalSender';
      if (threadTitle.isNotEmpty) subtitle = threadTitle;
    } else {
      title = 'Переслано';
    }

    return ChatMessageQuote(
      title: title,
      subtitle: subtitle,
      body: originalBody,
      accentColor: accent,
      textColor: textColor,
    );
  }

  Widget _attachmentImage(Map<String, dynamic> attachment, double width) {
    final local = attachment['local_bytes'];
    if (local is Uint8List) {
      return Image.memory(
        local,
        height: 180,
        width: width,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    return ChatNetworkImage(
      threadId: threadId,
      attachment: attachment,
      height: 180,
      width: width,
      fit: BoxFit.cover,
    );
  }
}

class _ChatVideoAttachmentPreview extends StatelessWidget {
  const _ChatVideoAttachmentPreview({
    required this.threadId,
    required this.attachment,
    required this.maxWidth,
    this.onOpen,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double maxWidth;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final local = attachment['local_bytes'];
    final url = galleryAttachmentUrl(attachment);

    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: maxWidth,
          height: 180,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (local is Uint8List)
                Image.memory(local, fit: BoxFit.cover)
              else if (url.isNotEmpty)
                GalleryVideoPlayer(
                  url: url,
                  autoplay: false,
                  showControls: false,
                )
              else
                const ColoredBox(
                  color: Colors.black26,
                  child: Icon(Icons.videocam_outlined, color: Colors.white54),
                ),
              const Align(
                alignment: Alignment.center,
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white70,
                  size: 48,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
