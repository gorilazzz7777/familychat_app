import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/network/chat_network_link.dart';
import '../../../../core/settings/app_settings_controller.dart';
import '../../data/chat_media_providers.dart';
import '../../data/chat_realtime_utils.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/media_local_index.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';
import '../../data/chat_location_utils.dart';
import '../../data/chat_media_auto_download.dart';
import '../../data/chat_voice_utils.dart';
import 'chat_bubble_clipper.dart';
import 'chat_image_album.dart';
import 'chat_link_preview_card.dart';
import 'chat_location_preview.dart';
import 'chat_media_layout.dart';
import 'chat_media_transfer_overlay.dart';
import 'chat_network_image.dart';
import 'chat_message_quote.dart';
import 'chat_message_reactions.dart';
import 'chat_message_read_status_icon.dart';
import 'chat_message_tap_target.dart';
import 'chat_mention_text.dart';
import 'chat_swipe_to_reply.dart';
import 'chat_video_note_player.dart';
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
    this.compactWithPrevious = false,
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
    this.onRetrySend,
    this.onCancelUpload,
    this.pendingMessageId,
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
  final bool compactWithPrevious;
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
  final VoidCallback? onRetrySend;
  final VoidCallback? onCancelUpload;
  final int? pendingMessageId;
  final bool isGroupLike;
  final List<Map<String, dynamic>> mentions;
  final DateTime? scheduledAt;
  final ChatLocationPoint? location;
  final Map<String, dynamic> messageMetadata;
  final bool canToggleVoiceTranscript;

  static const double _avatarSize = 32;

  Widget _buildMineStatus(ThemeData theme, Color color) {
    final status = readStatus!;
    if (status == 'failed') {
      final failedColor = theme.colorScheme.error;
      final icon = ChatMessageReadStatusIcon(
        status: status,
        color: failedColor,
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Не отправлено',
            style: theme.textTheme.labelSmall?.copyWith(color: failedColor),
          ),
          const SizedBox(width: 4),
          if (onRetrySend != null && !selectionMode)
            GestureDetector(
              onTap: onRetrySend,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: icon,
              ),
            )
          else
            icon,
        ],
      );
    }
    return ChatMessageReadStatusIcon(status: status, color: color);
  }

  bool _attachmentIsVideoNote(Map<String, dynamic> a) {
    if (a['kind'] != 'video' && !isVideoAttachment(a)) return false;
    final videoNote = messageMetadata['video_note'];
    return a['is_video_note'] == true ||
        a['is_video_note'] == 'true' ||
        videoNote is Map;
  }

  Map<String, dynamic>? _videoNoteAttachment() {
    for (final a in attachments) {
      if (_attachmentIsVideoNote(a)) return a;
    }
    return null;
  }

  int? _videoNoteDurationMs() {
    final videoNote = messageMetadata['video_note'];
    if (videoNote is Map) {
      final raw = videoNote['duration_ms'];
      if (raw is int) return raw;
      return int.tryParse('$raw');
    }
    return null;
  }

  /// Кружок без подписи и другого контента — рисуем без цветного пузыря.
  bool _isStandaloneVideoNote() {
    final note = _videoNoteAttachment();
    if (note == null) return false;
    if (_showBody(body, forward)) return false;
    if (replyTo != null || forward != null || location != null) return false;
    if (_linkPreviewUrl() != null) return false;
    var skippedNote = false;
    for (final a in attachments) {
      if (_attachmentIsVideoNote(a) &&
          !skippedNote &&
          (note['id'] == null || a['id'] == note['id'])) {
        skippedNote = true;
        continue;
      }
      if (isVoiceAttachment(a, messageMetadata: messageMetadata)) return false;
      if (chatAttachmentLooksLikeImage(a)) return false;
      if (a['kind'] == 'video' || isVideoAttachment(a)) return false;
      if (a['kind'] == 'file') return false;
    }
    return true;
  }

  /// Стикер без подписи — без цветного фона пузыря (как в Telegram).
  bool _isStandaloneSticker() {
    if (messageMetadata['sticker'] == null) return false;
    if (_showBody(body, forward)) return false;
    if (location != null) return false;
    if (_linkPreviewUrl() != null) return false;
    var hasImage = false;
    for (final a in attachments) {
      if (isVoiceAttachment(a, messageMetadata: messageMetadata)) return false;
      if (_attachmentIsVideoNote(a)) return false;
      if (a['kind'] == 'video' || isVideoAttachment(a)) return false;
      if (a['kind'] == 'file' && !chatAttachmentLooksLikeImage(a)) return false;
      if (chatAttachmentLooksLikeImage(a)) hasImage = true;
    }
    return hasImage;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeFmt = DateFormat.Hm();
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxBubbleWidth = screenWidth * 0.78;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : Colors.white;
    final textColor = isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final metaColor = isMine
        ? theme.colorScheme.onPrimary.withValues(alpha: 0.75)
        : theme.colorScheme.onSurfaceVariant;
    final quoteAccent = isMine ? const Color(0xFF8FD3FF) : theme.colorScheme.primary;
    final rowTint = (highlighted || selected)
        ? theme.colorScheme.primary.withValues(alpha: 0.12)
        : Colors.transparent;

    // Как в Telegram: хвостик только у последнего в серии одного автора.
    final showTail = !compactWithNext;
    const tailWidth = 8.0;
    final hasCaption = _showBody(body, forward);
    final hasVisualMedia = _hasVisualMedia();
    final standaloneVideoNote = _isStandaloneVideoNote();
    final standaloneSticker = _isStandaloneSticker();
    final framePad = hasVisualMedia ? 2.0 : 10.0;
    // Место под хвостик всегда — иначе пузыри без хвостика шире.
    final contentMaxWidth = maxBubbleWidth - framePad * 2 - tailWidth;

    final Widget bubble;
    if (standaloneVideoNote) {
      final note = _videoNoteAttachment()!;
      final noteMetaColor = isMine
          ? theme.colorScheme.primary.withValues(alpha: 0.9)
          : theme.colorScheme.onSurfaceVariant;
      bubble = ChatMessageTapTarget(
        // Короткий тап — воспроизведение кружка; меню — по long-press.
        onTap: selectionMode ? onTap : null,
        onLongPress: selectionMode ? null : onLongPress,
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatVideoNotePlayer(
              threadId: threadId,
              attachment: note,
              durationMs: _videoNoteDurationMs(),
              interactive: !selectionMode,
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (scheduledAt != null) ...[
                    Icon(Icons.schedule, size: 13, color: noteMetaColor),
                    const SizedBox(width: 4),
                    Text(
                      timeFmt.format(scheduledAt!.toLocal()),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: noteMetaColor),
                    ),
                  ] else if (createdAt != null)
                    Text(
                      timeFmt.format(createdAt!.toLocal()),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: noteMetaColor),
                    ),
                  if (isMine && readStatus != null) ...[
                    const SizedBox(width: 4),
                    _buildMineStatus(theme, noteMetaColor),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    } else if (standaloneSticker) {
      final stickerMetaColor = isMine
          ? theme.colorScheme.primary.withValues(alpha: 0.9)
          : theme.colorScheme.onSurfaceVariant;
      final stickerMaxW = (screenWidth * 0.55).clamp(120.0, 220.0);
      bubble = ChatMessageTapTarget(
        onTap: onTap,
        onLongPress: selectionMode ? null : onLongPress,
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (forward != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _buildForwardQuote(
                  forward!,
                  quoteAccent,
                  theme.colorScheme.onSurface,
                ),
              ),
            if (replyTo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: GestureDetector(
                  onTap: onReplyTap,
                  behavior: HitTestBehavior.opaque,
                  child: _buildReplyQuote(
                    replyTo!,
                    quoteAccent,
                    theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ..._buildAttachmentBlocks(
              textColor: theme.colorScheme.onSurface,
              metaColor: stickerMetaColor,
              maxWidth: stickerMaxW,
              hasLeadingContent: false,
              mediaRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (scheduledAt != null) ...[
                    Icon(Icons.schedule, size: 13, color: stickerMetaColor),
                    const SizedBox(width: 4),
                    Text(
                      timeFmt.format(scheduledAt!.toLocal()),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: stickerMetaColor),
                    ),
                  ] else if (createdAt != null)
                    Text(
                      timeFmt.format(createdAt!.toLocal()),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: stickerMetaColor),
                    ),
                  if (isMine && readStatus != null) ...[
                    const SizedBox(width: 4),
                    _buildMineStatus(theme, stickerMetaColor),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      bubble = ClipPath(
      clipper: ChatBubbleClipper(
        isMine: isMine,
        showTail: showTail,
        compactWithPrevious: compactWithPrevious,
        compactWithNext: compactWithNext,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: bubbleColor,
        elevation: 0,
        child: ChatMessageTapTarget(
          onTap: onTap,
          onLongPress: selectionMode ? null : onLongPress,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isMine ? framePad : framePad + tailWidth,
              hasVisualMedia ? 2 : 8,
              isMine ? framePad + tailWidth : framePad,
              6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (forward != null)
                  Padding(
                    padding: hasVisualMedia
                        ? const EdgeInsets.fromLTRB(8, 6, 8, 0)
                        : EdgeInsets.zero,
                    child: _buildForwardQuote(forward!, quoteAccent, textColor),
                  ),
                if (replyTo != null)
                  Padding(
                    padding: hasVisualMedia
                        ? const EdgeInsets.fromLTRB(8, 6, 8, 0)
                        : EdgeInsets.zero,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: selectionMode ? onTap : onReplyTap,
                      child: _buildReplyQuote(replyTo!, quoteAccent, textColor),
                    ),
                  ),
                ..._buildAttachmentBlocks(
                  textColor: textColor,
                  metaColor: metaColor,
                  maxWidth: contentMaxWidth,
                  hasLeadingContent: forward != null || replyTo != null,
                  mediaRadius: BorderRadius.only(
                    topLeft: Radius.circular(hasVisualMedia ? 12 : 8),
                    topRight: Radius.circular(hasVisualMedia ? 12 : 8),
                    bottomLeft: Radius.circular(
                      hasCaption || location != null ? 4 : 12,
                    ),
                    bottomRight: Radius.circular(
                      hasCaption || location != null ? 4 : 12,
                    ),
                  ),
                ),
                if (hasCaption)
                  Padding(
                    padding: hasVisualMedia
                        ? const EdgeInsets.fromLTRB(8, 6, 8, 0)
                        : EdgeInsets.zero,
                    child: ChatMentionText(
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
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                if (location != null) ...[
                  if (hasCaption || hasVisualMedia) const SizedBox(height: 8),
                  ChatLocationPreview(
                    location: location!,
                    isMine: isMine,
                    maxWidth: contentMaxWidth,
                  ),
                ],
                if (_linkPreviewUrl() != null) ...[
                  if (hasCaption || location != null) const SizedBox(height: 8),
                  ChatLinkPreviewCard(
                    url: _linkPreviewUrl()!,
                    isMine: isMine,
                    maxWidth: contentMaxWidth,
                  ),
                ],
                Padding(
                  padding: hasVisualMedia
                      ? const EdgeInsets.fromLTRB(8, 4, 8, 0)
                      : const EdgeInsets.only(top: 4),
                  child: Row(
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
                        _buildMineStatus(theme, metaColor),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    }

    return ChatSwipeToReply(
      onReply: selectionMode ? null : onSwipeReply,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: double.infinity,
        color: rowTint,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: selectionMode ? onTap : null,
            onLongPress: selectionMode ? onTap : null,
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
                      padding: const EdgeInsets.only(right: 6, bottom: 4),
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        onPressed: onTap,
                        icon: Icon(
                          selected
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  if (showGroupAvatarColumn) ...[
                    SizedBox(
                      width: _avatarSize,
                      height: _avatarSize,
                      child: showSenderAvatar
                          ? GestureDetector(
                              onTap: selectionMode ? onTap : onSenderAvatarTap,
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
                      alignment: isMine
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: standaloneVideoNote
                              ? screenWidth - 16
                              : maxBubbleWidth,
                        ),
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
                                    onReactionTap:
                                        selectionMode ? null : onReactionTap,
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
          ),
        ),
      ),
    );
  }

  bool _showBody(String body, Map<String, dynamic>? forward) {
    if (body.isEmpty) return false;
    if (attachments.isNotEmpty &&
        (messageMetadata['gif'] != null || messageMetadata['sticker'] != null)) {
      return false;
    }
    if (forward == null) return true;
    final original = forward['original_body']?.toString() ?? '';
    return body.trim() != original.trim();
  }

  String? _linkPreviewUrl() {
    if (attachments.isNotEmpty || location != null) return null;
    if (_showBody(body, forward)) {
      final fromBody = ChatMentionText.firstUrl(body);
      if (fromBody != null) return fromBody;
    }
    final original = forward?['original_body']?.toString() ?? '';
    return ChatMentionText.firstUrl(original);
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

  bool _hasVisualMedia() {
    for (final a in attachments) {
      if (isVoiceAttachment(a, messageMetadata: messageMetadata)) continue;
      if (a['kind'] == 'video' || isVideoAttachment(a)) {
        final videoNote = messageMetadata['video_note'];
        final isCircle = a['is_video_note'] == true ||
            videoNote is Map ||
            a['is_video_note'] == 'true';
        if (!isCircle) return true;
        continue;
      }
      if (chatAttachmentLooksLikeImage(a)) return true;
    }
    return false;
  }

  List<Widget> _buildAttachmentBlocks({
    required Color textColor,
    required Color metaColor,
    required double maxWidth,
    required bool hasLeadingContent,
    required BorderRadius mediaRadius,
  }) {
    final images = <Map<String, dynamic>>[];
    final rest = <Map<String, dynamic>>[];
    for (final a in attachments) {
      if (isVoiceAttachment(a, messageMetadata: messageMetadata) ||
          a['kind'] == 'video' ||
          isVideoAttachment(a) ||
          (a['kind'] == 'file' && !chatAttachmentLooksLikeImage(a))) {
        rest.add(a);
      } else if (chatAttachmentLooksLikeImage(a)) {
        images.add(a);
      } else {
        rest.add(a);
      }
    }

    final out = <Widget>[];
    var needsGap = hasLeadingContent;

    void addGap() {
      if (needsGap) out.add(const SizedBox(height: 8));
      needsGap = true;
    }

    if (images.isNotEmpty) {
      addGap();
      out.add(
        ChatImageAlbum(
          threadId: threadId,
          attachments: images,
          maxWidth: maxWidth,
          onImageTap: onImageTap,
          borderRadius: mediaRadius,
          uploadMessageId: pendingMessageId,
          onCancelUpload: onCancelUpload,
          messageMetadata: messageMetadata,
        ),
      );
    }

    for (final a in rest) {
      addGap();
      if (isVoiceAttachment(a, messageMetadata: messageMetadata)) {
        out.add(
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
              messageMetadata: messageMetadata,
              uploadMessageId: pendingMessageId,
              onCancelUpload: onCancelUpload,
            ),
          ),
        );
      } else if (a['kind'] == 'video' || isVideoAttachment(a)) {
        final isCircle = _attachmentIsVideoNote(a);
        if (isCircle) {
          out.add(
            ChatVideoNotePlayer(
              threadId: threadId,
              attachment: a,
              durationMs: _videoNoteDurationMs(),
              idleSize: (maxWidth * 0.72).clamp(160.0, 220.0),
              interactive: !selectionMode,
              messageMetadata: messageMetadata,
              uploadMessageId: pendingMessageId,
              onCancelUpload: onCancelUpload,
            ),
          );
        } else {
          out.add(
            _ChatVideoAttachmentPreview(
              threadId: threadId,
              attachment: a,
              maxWidth: maxWidth,
              circular: false,
              borderRadius: mediaRadius,
              onOpen: onImageTap != null ? () => onImageTap!(a) : null,
              messageMetadata: messageMetadata,
              uploadMessageId: pendingMessageId,
              onCancelUpload: onCancelUpload,
            ),
          );
        }
      } else {
        out.add(
          _ChatFileAttachmentRow(
            threadId: threadId,
            attachment: a,
            textColor: textColor,
            messageMetadata: messageMetadata,
            uploadMessageId: pendingMessageId,
            onCancelUpload: onCancelUpload,
          ),
        );
      }
    }

    return out;
  }
}

class _ChatVideoAttachmentPreview extends ConsumerStatefulWidget {
  const _ChatVideoAttachmentPreview({
    required this.threadId,
    required this.attachment,
    required this.maxWidth,
    this.circular = false,
    this.borderRadius,
    this.onOpen,
    this.messageMetadata = const {},
    this.uploadMessageId,
    this.onCancelUpload,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double maxWidth;
  final bool circular;
  final BorderRadius? borderRadius;
  final VoidCallback? onOpen;
  final Map<String, dynamic> messageMetadata;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;

  @override
  ConsumerState<_ChatVideoAttachmentPreview> createState() =>
      _ChatVideoAttachmentPreviewState();
}

class _ChatVideoAttachmentPreviewState
    extends ConsumerState<_ChatVideoAttachmentPreview> {
  late double _aspect;

  @override
  void initState() {
    super.initState();
    _aspect = chatAttachmentAspectRatio(widget.attachment) ?? (16 / 9);
    _probeLocalBytes();
  }

  @override
  void didUpdateWidget(covariant _ChatVideoAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment['id'] != widget.attachment['id'] ||
        oldWidget.attachment['file_url'] != widget.attachment['file_url'] ||
        oldWidget.attachment['local_bytes'] !=
            widget.attachment['local_bytes']) {
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
    final attachment = widget.attachment;
    final maxWidth = widget.maxWidth;
    final circular = widget.circular;
    final localBytes = attachment['local_bytes'];
    final size = circular
        ? (maxWidth * 0.72).clamp(160.0, 220.0)
        : maxWidth;
    final fitted = circular
        ? Size(size, size)
        : chatFitMediaSize(
            aspectRatio: _aspect,
            maxWidth: size,
            maxHeight: chatMediaMaxThumbHeight(size),
          );
    Widget background;
    if (isSafeUiPreviewBytes(localBytes)) {
      background = Image.memory(
        localBytes as Uint8List,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      background = ChatNetworkImage(
        threadId: widget.threadId,
        attachment: attachment,
        fit: BoxFit.cover,
        uploadMessageId: widget.uploadMessageId,
        onCancelUpload: widget.onCancelUpload,
        messageMetadata: widget.messageMetadata,
        borderRadius: widget.borderRadius,
      );
    }

    final content = SizedBox(
      width: fitted.width,
      height: fitted.height,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          background,
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.42),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
        ],
      ),
    );

    return GestureDetector(
      onTap: widget.onOpen,
      behavior: HitTestBehavior.opaque,
      child: circular
          ? ClipOval(child: content)
          : ClipRRect(
              borderRadius: widget.borderRadius ?? BorderRadius.circular(10),
              child: content,
            ),
    );
  }
}

class _ChatFileAttachmentRow extends ConsumerStatefulWidget {
  const _ChatFileAttachmentRow({
    required this.threadId,
    required this.attachment,
    required this.textColor,
    this.messageMetadata = const {},
    this.uploadMessageId,
    this.onCancelUpload,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final Color textColor;
  final Map<String, dynamic> messageMetadata;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;

  @override
  ConsumerState<_ChatFileAttachmentRow> createState() =>
      _ChatFileAttachmentRowState();
}

class _ChatFileAttachmentRowState extends ConsumerState<_ChatFileAttachmentRow> {
  @override
  void initState() {
    super.initState();
    _scheduleAutoDownload();
  }

  void _scheduleAutoDownload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final attachmentId = chatAsInt(widget.attachment['id']);
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

  Future<void> _openFile() async {
    final url = widget.attachment['file_url']?.toString();
    if (url != null && url.isNotEmpty) {
      await launchUrl(Uri.parse(url));
      return;
    }
    final attachmentId = chatAsInt(widget.attachment['id']);
    if (attachmentId == null) return;
    final bytes = await ref.read(chatAttachmentDownloadManagerProvider).startDownload(
          threadId: widget.threadId,
          attachmentId: attachmentId,
          manual: true,
        );
    if (!mounted || bytes == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Файл загружен')),
    );
  }

  bool _skipDownloadOverlay() {
    MediaLocalIndex.hydrateAttachment(widget.attachment);
    return ChatMediaAutoDownloadPolicy.isLocallyAvailable(
          threadId: widget.threadId,
          attachment: widget.attachment,
        ) ||
        ChatMediaAutoDownloadPolicy.hasRemoteContentUrl(
          attachment: widget.attachment,
        );
  }

  @override
  Widget build(BuildContext context) {
    return ChatMediaTransferOverlay(
      threadId: widget.threadId,
      attachment: widget.attachment,
      uploadMessageId: widget.uploadMessageId,
      onCancelUpload: widget.onCancelUpload,
      onDownloadTap: _openFile,
      showManualDownload: !_skipDownloadOverlay(),
      child: InkWell(
        onTap: _openFile,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, color: widget.textColor),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.attachment['filename']?.toString() ?? 'Файл',
                style: TextStyle(color: widget.textColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
