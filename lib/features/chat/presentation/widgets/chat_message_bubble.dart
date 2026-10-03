import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/network/chat_network_link.dart';
import '../../../../core/settings/app_settings_controller.dart';
import '../../data/chat_media_providers.dart';
import '../../data/chat_realtime_utils.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/media/gallery_video_thumbnail.dart';
import '../../../../core/media/local_device_file.dart';
import '../../../../core/media/media_local_index.dart';
import '../../../../core/media/pdf_page_preview.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/widgets/gallery_video_player.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';
import '../../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../data/chat_location_utils.dart';
import '../../data/chat_media_auto_download.dart';
import '../../data/chat_voice_utils.dart';
import 'chat_animated_media_scope.dart';
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
    this.senderAvatarLocalPath,
    this.senderAvatarMemoryBytes,
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
    this.onForwardTap,
    this.onSwipeReply,
    this.onReactionTap,
    this.onRetrySend,
    this.onCancelUpload,
    this.pendingMessageId,
    this.isGroupLike = false,
    this.mentions = const [],
    this.textEntities = const [],
    this.scheduledAt,
    this.location,
    this.messageMetadata = const {},
    this.canToggleVoiceTranscript = false,
    this.collapseBodyAfterLines,
    this.bodyExpanded = false,
    this.onToggleBodyExpand,
    this.onOpenUrl,
    this.showLinkPreview = true,
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
  final String? senderAvatarLocalPath;
  final List<int>? senderAvatarMemoryBytes;
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
  final VoidCallback? onForwardTap;
  /// Свайп влево — то же, что «Ответить» в меню.
  final VoidCallback? onSwipeReply;
  final void Function(String emoji)? onReactionTap;
  final VoidCallback? onRetrySend;
  final VoidCallback? onCancelUpload;
  final int? pendingMessageId;
  final bool isGroupLike;
  final List<Map<String, dynamic>> mentions;
  final List<ChatTextEntity> textEntities;
  final DateTime? scheduledAt;
  final ChatLocationPoint? location;
  final Map<String, dynamic> messageMetadata;
  final bool canToggleVoiceTranscript;

  /// Для каналов: свернуть длинный текст после N строк.
  final int? collapseBodyAfterLines;
  final bool bodyExpanded;
  final VoidCallback? onToggleBodyExpand;
  /// Return true if the URL was handled in-app (e.g. t.me → TDLib jump).
  final Future<bool> Function(String url)? onOpenUrl;
  /// When false, skip OG card (open/scroll settle) — host links still work.
  final bool showLinkPreview;

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
  /// В т.ч. анимированные TG-стикеры (webm/mp4).
  bool _isStandaloneSticker() {
    if (messageMetadata['sticker'] == null) return false;
    if (_showBody(body, forward)) return false;
    if (location != null) return false;
    if (_linkPreviewUrl() != null) return false;
    var hasMedia = false;
    for (final a in attachments) {
      if (isVoiceAttachment(a, messageMetadata: messageMetadata)) return false;
      if (_attachmentIsVideoNote(a)) return false;
      if (a['kind'] == 'video' || isVideoAttachment(a)) {
        hasMedia = true;
        continue;
      }
      if (a['kind'] == 'file' && !chatAttachmentLooksLikeImage(a)) return false;
      if (chatAttachmentLooksLikeImage(a)) hasMedia = true;
    }
    return hasMedia;
  }

  bool get _isAnimatedMediaMessage =>
      messageMetadata['gif'] != null || messageMetadata['sticker'] != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeFmt = DateFormat.Hm();
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxBubbleWidth = screenWidth * 0.78;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : Colors.white;
    final textColor =
        isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final metaColor = isMine
        ? theme.colorScheme.onPrimary.withValues(alpha: 0.75)
        : theme.colorScheme.onSurfaceVariant;
    final quoteAccent =
        isMine ? const Color(0xFF8FD3FF) : theme.colorScheme.primary;
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
              child: _buildTimeMetaRow(
                theme: theme,
                metaColor: noteMetaColor,
                timeFmt: timeFmt,
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
                child: GestureDetector(
                  onTap: onForwardTap,
                  behavior: HitTestBehavior.opaque,
                  child: _buildForwardQuote(
                    forward!,
                    quoteAccent,
                  ),
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
              child: _buildTimeMetaRow(
                theme: theme,
                metaColor: stickerMetaColor,
                timeFmt: timeFmt,
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
          // Media tiles own short taps (open photo/video). Menu = long-press,
          // same as video-notes — otherwise parent onTap steals album taps.
          onTap: (hasVisualMedia && !selectionMode) ? null : onTap,
          onLongPress: selectionMode ? null : onLongPress,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isMine ? framePad : framePad + tailWidth,
              hasVisualMedia
                  ? 2
                  : (forward != null ? 6.0 : 8.0),
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
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: selectionMode ? onTap : onForwardTap,
                      child: _buildForwardQuote(forward!, quoteAccent),
                    ),
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
                    child: _buildCaptionBody(
                      theme: theme,
                      textColor: textColor,
                      maxWidth: contentMaxWidth,
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
                if (showLinkPreview && _linkPreviewUrl() != null) ...[
                  if (hasCaption || location != null) const SizedBox(height: 8),
                  ChatLinkPreviewCard(
                    url: _linkPreviewUrl()!,
                    isMine: isMine,
                    maxWidth: contentMaxWidth,
                    onOpenUrl: onOpenUrl,
                  ),
                ],
                if (reactions.isNotEmpty)
                  Padding(
                    padding: hasVisualMedia
                        ? const EdgeInsets.fromLTRB(8, 6, 8, 0)
                        : const EdgeInsets.only(top: 6),
                    child: ChatMessageReactionsRow(
                      reactions: reactions,
                      alignEnd: isMine,
                      onReactionTap:
                          selectionMode ? null : onReactionTap,
                    ),
                  ),
                Padding(
                  padding: hasVisualMedia
                      ? const EdgeInsets.fromLTRB(8, 4, 8, 0)
                      : const EdgeInsets.only(top: 4),
                  child: _buildTimeMetaRow(
                    theme: theme,
                    metaColor: metaColor,
                    timeFmt: timeFmt,
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
                bottom: compactWithNext ? 1 : 6,
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
                              ? LucideIcons.circle_check
                              : LucideIcons.circle,
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
                                localFilePath: senderAvatarLocalPath,
                                memoryBytes: senderAvatarMemoryBytes,
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
                        child: standaloneVideoNote || standaloneSticker
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: isMine
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  bubble,
                                  if (reactions.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: ChatMessageReactionsRow(
                                        reactions: reactions,
                                        alignEnd: isMine,
                                        onReactionTap: selectionMode
                                            ? null
                                            : onReactionTap,
                                      ),
                                    ),
                                ],
                              )
                            : bubble,
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
    // Forward header is separate; body always shows as normal message text.
    return true;
  }

  bool get _fromTelegram =>
      messageMetadata['source']?.toString() == 'telegram';

  Widget _buildCaptionBody({
    required ThemeData theme,
    required Color textColor,
    required double maxWidth,
  }) {
    final baseStyle = theme.textTheme.bodyMedium?.copyWith(color: textColor) ??
        TextStyle(color: textColor);
    final mentionStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
      color: isMine ? const Color(0xFF8FD3FF) : theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final linkStyle = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: isMine ? const Color(0xFF8FD3FF) : theme.colorScheme.primary,
      decoration: TextDecoration.none,
    );
    final limit = collapseBodyAfterLines;
    final canCollapse = limit != null &&
        limit > 0 &&
        onToggleBodyExpand != null &&
        _bodyExceedsLines(body, baseStyle, maxWidth, limit);

    final text = ChatMentionText(
      body: body,
      mentions: mentions,
      entities: textEntities,
      style: baseStyle,
      mentionStyle: mentionStyle,
      linkStyle: linkStyle,
      maxLines: canCollapse && !bodyExpanded ? limit : null,
      overflow: canCollapse && !bodyExpanded ? TextOverflow.ellipsis : null,
      onOpenUrl: onOpenUrl,
    );

    if (!canCollapse) return text;

    // Telegram-style text affordance (not a centered pill): sits in the text
    // flow, left-aligned, with a generous hit target and no chip fill.
    final expandLabel = bodyExpanded ? 'Свернуть' : 'Ещё';
    final linkFg = isMine
        ? const Color(0xFF8FD3FF)
        : theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        text,
        Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            onTap: onToggleBodyExpand,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              // ~44dp tap height; horizontal pad keeps the label easy to hit
              // without looking like a full-width button slab.
              padding: const EdgeInsets.fromLTRB(0, 6, 12, 4),
              child: Text(
                expandLabel,
                style: (theme.textTheme.bodyMedium ?? const TextStyle())
                    .copyWith(
                  color: linkFg,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static bool _bodyExceedsLines(
    String text,
    TextStyle style,
    double maxWidth,
    int maxLines,
  ) {
    if (text.isEmpty || maxWidth <= 0) return false;
    final newlineCount = '\n'.allMatches(text).length;
    if (newlineCount >= maxLines) return true;
    // Approximate wrapped lines without TextPainter (avoids TextDirection issues).
    final fontSize = style.fontSize ?? 14;
    final avgCharWidth = fontSize * 0.52;
    final charsPerLine = (maxWidth / avgCharWidth).floor().clamp(8, 10000);
    var lines = 0;
    for (final paragraph in text.split('\n')) {
      if (paragraph.isEmpty) {
        lines += 1;
      } else {
        lines += ((paragraph.length + charsPerLine - 1) / charsPerLine)
            .floor()
            .clamp(1, 100000);
      }
      if (lines > maxLines) return true;
    }
    return lines > maxLines;
  }

  /// Meta-ряд справа: [лого TG] · время · галочки.
  Widget _buildTimeMetaRow({
    required ThemeData theme,
    required Color metaColor,
    required DateFormat timeFmt,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_fromTelegram) ...[
          Image.asset(
            'assets/logo/tg.png',
            width: 12,
            height: 12,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: 4),
        ],
        if (scheduledAt != null) ...[
          Icon(LucideIcons.clock, size: 13, color: metaColor),
          const SizedBox(width: 4),
          Text(
            timeFmt.format(scheduledAt!.toLocal()),
            style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
          ),
        ] else if (createdAt != null)
          Text(
            timeFmt.format(createdAt!.toLocal()),
            style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
          ),
        if (isMine && readStatus != null) ...[
          const SizedBox(width: 4),
          _buildMineStatus(theme, metaColor),
        ],
      ],
    );
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
  ) {
    final originalSender = fwd['original_sender_name']?.toString() ?? '';
    final threadTitle = fwd['original_thread_title']?.toString() ?? '';
    final name = originalSender.isNotEmpty
        ? originalSender
        : (threadTitle.isNotEmpty ? threadTitle : null);
    return ChatMessageForwardHeader(
      name: name,
      accentColor: accent,
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
    // Keep send-order: images + regular videos can share one album grid
    // (Telegram media groups). Video notes / voice / files stay separate.
    final albumMedia = <Map<String, dynamic>>[];
    final rest = <Map<String, dynamic>>[];
    for (final a in attachments) {
      if (isVoiceAttachment(a, messageMetadata: messageMetadata) ||
          _attachmentIsVideoNote(a) ||
          (a['kind'] == 'file' && !chatAttachmentLooksLikeImage(a))) {
        rest.add(a);
      } else if (a['kind'] == 'video' || isVideoAttachment(a)) {
        albumMedia.add(a);
      } else if (chatAttachmentLooksLikeImage(a)) {
        albumMedia.add(a);
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

    void addStandaloneVideo(Map<String, dynamic> a) {
      final isCircle = _attachmentIsVideoNote(a);
      // Single-video message: inline play in bubble (not gallery).
      final att = Map<String, dynamic>.from(a)..['prefer_inline_play'] = true;
      if (isCircle) {
        out.add(
          ChatVideoNotePlayer(
            threadId: threadId,
            attachment: att,
            durationMs: _videoNoteDurationMs(),
            idleSize: (maxWidth * 0.72).clamp(160.0, 220.0),
            interactive: !selectionMode,
            messageMetadata: messageMetadata,
            uploadMessageId: pendingMessageId,
            onCancelUpload: onCancelUpload,
          ),
        );
      } else if (_isAnimatedMediaMessage) {
        out.add(
          _ChatGifVideoPreview(
            threadId: threadId,
            attachment: att,
            maxWidth: maxWidth,
            borderRadius: mediaRadius,
            onOpen: onImageTap != null ? () => onImageTap!(att) : null,
            preferSquare: messageMetadata['sticker'] != null,
          ),
        );
      } else {
        out.add(
          _ChatVideoAttachmentPreview(
            threadId: threadId,
            attachment: att,
            maxWidth: maxWidth,
            circular: false,
            borderRadius: mediaRadius,
            onRequestDownload:
                onImageTap != null ? () => onImageTap!(att) : null,
            onOpenFullscreen: onImageTap != null
                ? () => onImageTap!(
                      Map<String, dynamic>.from(att)
                        ..['force_fullscreen'] = true,
                    )
                : null,
            messageMetadata: messageMetadata,
            messageCreatedAt: createdAt,
            uploadMessageId: pendingMessageId,
            onCancelUpload: onCancelUpload,
          ),
        );
      }
    }

    if (albumMedia.length >= 2) {
      addGap();
      out.add(
        ChatImageAlbum(
          threadId: threadId,
          attachments: albumMedia,
          maxWidth: maxWidth,
          onImageTap: onImageTap,
          borderRadius: mediaRadius,
          uploadMessageId: pendingMessageId,
          onCancelUpload: onCancelUpload,
          messageMetadata: messageMetadata,
          messageCreatedAt: createdAt,
        ),
      );
    } else if (albumMedia.length == 1) {
      final a = albumMedia.first;
      if (a['kind'] == 'video' || isVideoAttachment(a)) {
        addGap();
        addStandaloneVideo(a);
      } else {
        addGap();
        out.add(
          ChatImageAlbum(
            threadId: threadId,
            attachments: albumMedia,
            maxWidth: maxWidth,
            onImageTap: onImageTap,
            borderRadius: mediaRadius,
            uploadMessageId: pendingMessageId,
            onCancelUpload: onCancelUpload,
            messageMetadata: messageMetadata,
            messageCreatedAt: createdAt,
          ),
        );
      }
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
        // Video notes land here; regular videos are handled above.
        addStandaloneVideo(a);
      } else {
        out.add(
          _ChatFileAttachmentRow(
            threadId: threadId,
            attachment: a,
            isMine: isMine,
            textColor: textColor,
            metaColor: metaColor,
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

/// TG GIF / анимированный стикер (mp4/webm) в пузыре.
///
/// Autoplay при первом показе (пока не было скролла) → стоп на скролле →
/// дальше только тап (play/pause). Fullscreen — иконка «развернуть».
class _ChatGifVideoPreview extends ConsumerStatefulWidget {
  const _ChatGifVideoPreview({
    required this.threadId,
    required this.attachment,
    required this.maxWidth,
    this.borderRadius,
    this.onOpen,
    this.preferSquare = false,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double maxWidth;
  final BorderRadius? borderRadius;
  final VoidCallback? onOpen;
  final bool preferSquare;

  @override
  ConsumerState<_ChatGifVideoPreview> createState() =>
      _ChatGifVideoPreviewState();
}

class _ChatGifVideoPreviewState extends ConsumerState<_ChatGifVideoPreview> {
  static const _maxActivePlayers = 2;
  static int _activePlayers = 0;

  late double _aspect;
  var _aspectLocked = false;
  var _visibleEnough = false;
  var _playing = false;
  var _holdsSlot = false;
  var _didAutoplay = false;
  var _lastScrollGen = -1;
  String? _thumbPath;
  Timer? _visDebounce;

  @override
  void initState() {
    super.initState();
    _aspect = chatAttachmentAspectRatio(widget.attachment) ?? 1.0;
    unawaited(_loadThumb());
  }

  @override
  void dispose() {
    _visDebounce?.cancel();
    _releaseSlot();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ctrl = ChatAnimatedMediaScope.maybeOf(context);
    final gen = ctrl?.scrollGeneration ?? 0;
    if (gen != _lastScrollGen) {
      _lastScrollGen = gen;
      _visDebounce?.cancel();
      if (_playing) {
        _stopPlayback(update: false);
        // Defer setState — may be called during build/dependOn.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant _ChatGifVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment['id'] != widget.attachment['id'] ||
        oldWidget.attachment['file_url'] != widget.attachment['file_url']) {
      _stopPlayback(update: false);
      _aspectLocked = false;
      _didAutoplay = false;
      _aspect = chatAttachmentAspectRatio(widget.attachment) ?? _aspect;
      _thumbPath = null;
      unawaited(_loadThumb());
    }
  }

  void _applyAspect(double next) {
    if (_aspectLocked) return;
    if (next <= 0 || !next.isFinite) return;
    if ((next - _aspect).abs() < 0.02) {
      _aspectLocked = true;
      return;
    }
    setState(() {
      _aspect = next;
      _aspectLocked = true;
    });
  }

  Future<void> _loadThumb() async {
    final att = Map<String, dynamic>.from(widget.attachment);
    if (att['kind']?.toString() != 'video') {
      att['kind'] = 'video';
    }
    final path = await GalleryVideoThumbnail.ensureForAttachment(
      att,
      maxWidth: 512,
      timeMs: 0,
    );
    if (!mounted || path == null || path.isEmpty) return;
    setState(() => _thumbPath = path);
  }

  bool _acquireSlot() {
    if (_holdsSlot) return true;
    if (_activePlayers >= _maxActivePlayers) return false;
    _activePlayers++;
    _holdsSlot = true;
    return true;
  }

  void _releaseSlot() {
    if (!_holdsSlot) return;
    _holdsSlot = false;
    _activePlayers = (_activePlayers - 1).clamp(0, _maxActivePlayers);
  }

  void _stopPlayback({required bool update}) {
    _visDebounce?.cancel();
    if (!_playing && !_holdsSlot) return;
    _playing = false;
    _releaseSlot();
    if (update && mounted) setState(() {});
  }

  void _startPlayback({bool userInitiated = false}) {
    final ctrl = ChatAnimatedMediaScope.maybeOf(context);
    if (ctrl?.isScrolling == true) return;
    // После любого скролла autoplay запрещён; тап — нет.
    if (!userInitiated && ctrl?.suppressAutoplay == true) return;
    if (!_visibleEnough) return;
    if (!_acquireSlot()) return;
    setState(() => _playing = true);
  }

  void _togglePlay() {
    if (_playing) {
      _stopPlayback(update: true);
      return;
    }
    // Explicit tap — play even if visibility debounce hasn't settled yet.
    _visibleEnough = true;
    _startPlayback(userInitiated: true);
  }

  void _onVisibility(double fraction) {
    final enough = fraction >= 0.5;
    if (enough == _visibleEnough) return;
    _visibleEnough = enough;
    _visDebounce?.cancel();
    if (!enough) {
      _visDebounce = Timer(const Duration(milliseconds: 200), () {
        if (!mounted) return;
        if (!_visibleEnough) _stopPlayback(update: true);
      });
      return;
    }
    _visDebounce = Timer(const Duration(milliseconds: 280), () {
      if (!mounted || !_visibleEnough) return;
      final ctrl = ChatAnimatedMediaScope.maybeOf(context);
      if (ctrl?.isScrolling == true) return;
      if (ctrl?.suppressAutoplay == true) return;
      if (_didAutoplay || _playing) return;
      _didAutoplay = true;
      _startPlayback();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when scroll generation / suppress flags change.
    ChatAnimatedMediaScope.maybeOf(context);

    MediaLocalIndex.hydrateAttachment(widget.attachment);
    final fitted = chatFitMediaSize(
      aspectRatio: _aspect,
      maxWidth: widget.maxWidth,
      maxHeight: chatMediaMaxThumbHeight(widget.maxWidth),
    );
    final localPath = galleryLocalDevicePath(widget.attachment);
    final url = chatAttachmentImageUrl(
      repo: ref.read(familychatRepositoryProvider),
      threadId: widget.threadId,
      attachment: widget.attachment,
    );
    final attId = widget.attachment['id'];
    final visibilityKey = ValueKey('gif-vis:$attId:${widget.threadId}');

    final thumb = _thumbPath != null
        ? localDeviceFileImage(
            path: _thumbPath!,
            width: fitted.width,
            height: fitted.height,
            fit: BoxFit.cover,
          )
        : const ColoredBox(color: Color(0x11000000));

    final body = Stack(
      fit: StackFit.expand,
      children: [
        thumb,
        if (_playing)
          GalleryVideoPlayer(
            key: ValueKey('gif-player:$attId'),
            url: url,
            localPath: localPath.isEmpty ? null : localPath,
            fit: BoxFit.cover,
            autoplay: true,
            looping: true,
            muted: true,
            showControls: false,
            placeholder: const SizedBox.shrink(),
            onResolvedSize: (size) {
              if (size.height <= 0) return;
              _applyAspect(size.width / size.height);
            },
          ),
        if (!_playing)
          Center(
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                LucideIcons.play,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        if (widget.onOpen != null)
          Positioned(
            top: 6,
            right: 6,
            child: Material(
              color: Colors.black.withValues(alpha: 0.42),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onOpen,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    LucideIcons.maximize_2,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    return VisibilityDetector(
      key: visibilityKey,
      onVisibilityChanged: (info) => _onVisibility(info.visibleFraction),
      child: GestureDetector(
        onTap: _togglePlay,
        behavior: HitTestBehavior.opaque,
        child: ClipRRect(
          borderRadius: widget.borderRadius ?? BorderRadius.circular(10),
          child: SizedBox(
            width: fitted.width,
            height: fitted.height,
            child: body,
          ),
        ),
      ),
    );
  }
}

class _ChatVideoAttachmentPreview extends ConsumerStatefulWidget {
  const _ChatVideoAttachmentPreview({
    required this.threadId,
    required this.attachment,
    required this.maxWidth,
    this.circular = false,
    this.borderRadius,
    this.onRequestDownload,
    this.onOpenFullscreen,
    this.messageMetadata = const {},
    this.messageCreatedAt,
    this.uploadMessageId,
    this.onCancelUpload,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final double maxWidth;
  final bool circular;
  final BorderRadius? borderRadius;
  /// First tap when the mp4 is not local yet — parent starts download.
  final VoidCallback? onRequestDownload;
  /// Tap while already playing — open fullscreen viewer.
  final VoidCallback? onOpenFullscreen;
  final Map<String, dynamic> messageMetadata;
  final DateTime? messageCreatedAt;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;

  @override
  ConsumerState<_ChatVideoAttachmentPreview> createState() =>
      _ChatVideoAttachmentPreviewState();
}

class _ChatVideoAttachmentPreviewState
    extends ConsumerState<_ChatVideoAttachmentPreview> {
  late double _aspect;
  bool _playing = false;
  bool _waitingForDownload = false;
  String? _generatedThumbPath;

  String get _videoPath {
    final v = widget.attachment['video_local_path']?.toString().trim() ?? '';
    if (v.isNotEmpty) return v;
    final local = widget.attachment['local_device_path']?.toString().trim() ?? '';
    final lower = local.toLowerCase();
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mkv')) {
      return local;
    }
    return '';
  }

  /// Real streamable HTTPS (S3 / CDN). FamilyChat `/attachments/…/content`
  /// proxy URLs are NOT playable for TDLib file ids — those need download.
  String get _streamableVideoUrl {
    for (final key in ['file_url', 'url', 'video_url']) {
      final raw = widget.attachment[key]?.toString().trim() ?? '';
      if (raw.startsWith('https://') || raw.startsWith('http://')) {
        final uri = Uri.tryParse(raw);
        if (uri == null) continue;
        if (uri.path.contains('/attachments/') &&
            uri.path.contains('/content')) {
          continue;
        }
        return raw;
      }
    }
    return '';
  }

  bool get _downloading => widget.attachment['is_downloading'] == true;

  @override
  void initState() {
    super.initState();
    _aspect = chatAttachmentAspectRatio(widget.attachment) ?? (16 / 9);
    if (chatAttachmentAspectRatio(widget.attachment) == null) {
      _probeLocalBytes();
    }
    unawaited(_ensureThumb());
  }

  @override
  void didUpdateWidget(covariant _ChatVideoAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPath =
        oldWidget.attachment['video_local_path']?.toString().trim() ?? '';
    final newPath = _videoPath;
    if (oldWidget.attachment['id'] != widget.attachment['id'] ||
        oldWidget.attachment['file_url'] != widget.attachment['file_url'] ||
        oldWidget.attachment['local_bytes'] !=
            widget.attachment['local_bytes'] ||
        oldWidget.attachment['thumbnail_bytes'] !=
            widget.attachment['thumbnail_bytes'] ||
        oldWidget.attachment['thumbnail_local_path'] !=
            widget.attachment['thumbnail_local_path'] ||
        oldWidget.attachment['local_device_path'] !=
            widget.attachment['local_device_path'] ||
        oldWidget.attachment['width'] != widget.attachment['width'] ||
        oldWidget.attachment['height'] != widget.attachment['height'] ||
        oldPath != newPath ||
        oldWidget.attachment['is_downloading'] !=
            widget.attachment['is_downloading'] ||
        oldWidget.attachment['download_progress'] !=
            widget.attachment['download_progress']) {
      _aspect = chatAttachmentAspectRatio(widget.attachment) ?? _aspect;
      if (chatAttachmentAspectRatio(widget.attachment) == null) {
        _probeLocalBytes();
      }
      unawaited(_ensureThumb());
    }
    // Download finished while we were waiting → start muted inline playback.
    if (_waitingForDownload && newPath.isNotEmpty) {
      _waitingForDownload = false;
      if (!_playing && mounted) {
        setState(() => _playing = true);
      }
    }
  }

  Future<void> _probeLocalBytes() async {
    if (chatAttachmentAspectRatio(widget.attachment) != null) return;
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

  Future<void> _ensureThumb() async {
    final thumbPath =
        widget.attachment['thumbnail_local_path']?.toString().trim() ?? '';
    if (thumbPath.isNotEmpty) {
      if (_generatedThumbPath != null && mounted) {
        setState(() => _generatedThumbPath = null);
      }
      return;
    }
    if (isSafeUiPreviewBytes(widget.attachment['thumbnail_bytes']) ||
        isSafeUiPreviewBytes(widget.attachment['local_bytes'])) {
      return;
    }
    // After the mp4 lands, bake a still so the cell is not a grey box.
    final videoPath = _videoPath;
    if (videoPath.isEmpty) return;
    final att = Map<String, dynamic>.from(widget.attachment)
      ..['video_local_path'] = videoPath
      ..['kind'] = 'video';
    final path = await GalleryVideoThumbnail.ensureForAttachment(
      att,
      maxWidth: 512,
      timeMs: 0,
    );
    if (!mounted || path == null || path.isEmpty) return;
    if (_generatedThumbPath == path) return;
    setState(() => _generatedThumbPath = path);
  }

  /// Prefer thumbnail image for the bubble preview — never decode mp4 as image.
  Map<String, dynamic> _previewAttachment() {
    final a = Map<String, dynamic>.from(widget.attachment);
    final thumbBytes = a['thumbnail_bytes'];
    final thumbPath = a['thumbnail_local_path']?.toString().trim() ?? '';
    final generated = _generatedThumbPath?.trim() ?? '';
    final localPath = a['local_device_path']?.toString().trim() ?? '';
    final contentType = a['content_type']?.toString() ?? '';
    final looksLikeVideoFile = contentType.startsWith('video/') ||
        localPath.toLowerCase().endsWith('.mp4') ||
        localPath.toLowerCase().endsWith('.mov') ||
        localPath.toLowerCase().endsWith('.webm');

    if (thumbPath.isNotEmpty && localDeviceFileExists(thumbPath)) {
      a['local_device_path'] = thumbPath;
      a.remove('local_bytes');
      // Keep thumbnail_bytes as ChatNetworkImage fallback if decode fails.
      a.remove('video_local_path');
      return a;
    }
    if (generated.isNotEmpty && localDeviceFileExists(generated)) {
      a['local_device_path'] = generated;
      a.remove('local_bytes');
      a.remove('video_local_path');
      return a;
    }
    if (isSafeUiPreviewBytes(thumbBytes)) {
      a['local_bytes'] = thumbBytes;
      a.remove('local_device_path');
      a.remove('video_local_path');
      return a;
    }
    if (isSafeUiPreviewBytes(a['local_bytes'])) {
      a.remove('local_device_path');
      a.remove('video_local_path');
      return a;
    }
    if (looksLikeVideoFile || _videoPath.isNotEmpty) {
      // Avoid grey broken Image.file on video binary.
      a.remove('local_device_path');
      a.remove('video_local_path');
    }
    return a;
  }

  Future<void> _onTap() async {
    if (_downloading) return;
    if (_playing) {
      // Play/pause handled by GalleryVideoPlayer overlay; bubble tap ignored.
      return;
    }
    final path = _videoPath;
    if (path.isNotEmpty) {
      await _ensureThumb();
      if (!mounted) return;
      setState(() => _playing = true);
      return;
    }
    // FamilyChat may stream a real HTTPS mp4. TDLib videos only have a local
    // path after download — never treat the FC content-proxy URL as streamable
    // (that left _playing=true with an empty player and no download).
    final streamUrl = _streamableVideoUrl;
    if (streamUrl.isNotEmpty) {
      if (!mounted) return;
      setState(() => _playing = true);
      return;
    }
    if (!mounted) return;
    setState(() => _waitingForDownload = true);
    widget.onRequestDownload?.call();
  }

  @override
  Widget build(BuildContext context) {
    final previewAtt = _previewAttachment();
    final maxWidth = widget.maxWidth;
    final circular = widget.circular;
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

    final videoPath = _videoPath;
    final streamUrl = _streamableVideoUrl;
    final canPlay = videoPath.isNotEmpty || streamUrl.isNotEmpty;
    final showSpinner =
        _downloading || (_waitingForDownload && videoPath.isEmpty);

    final background = ChatNetworkImage(
      threadId: widget.threadId,
      attachment: previewAtt,
      width: fitted.width,
      height: fitted.height,
      fit: BoxFit.cover,
      uploadMessageId: widget.uploadMessageId,
      onCancelUpload: widget.onCancelUpload,
      messageMetadata: widget.messageMetadata,
      messageCreatedAt: widget.messageCreatedAt,
      borderRadius: widget.borderRadius,
      // Bubble owns the download spinner ([showSpinner]) — avoid a second ring.
      showTransferOverlay: false,
      onResolvedSize: (resolved) {
        if (resolved.height <= 0) return;
        if (chatAttachmentAspectRatio(widget.attachment) != null) return;
        _applyAspect(resolved.width / resolved.height);
      },
    );

    final content = SizedBox(
      width: fitted.width,
      height: fitted.height,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          background,
          if (_playing && canPlay)
            GalleryVideoPlayer(
              key: ValueKey(
                'bubble-video:${videoPath.isNotEmpty ? videoPath : streamUrl}',
              ),
              url: streamUrl,
              localPath: videoPath.isNotEmpty ? videoPath : null,
              fit: BoxFit.cover,
              autoplay: true,
              looping: false,
              muted: true,
              showControls: false,
              showScrubber: true,
              placeholder: const SizedBox.shrink(),
              onResolvedSize: (resolved) {
                if (resolved.height <= 0) return;
                if (chatAttachmentAspectRatio(widget.attachment) != null) {
                  return;
                }
                _applyAspect(resolved.width / resolved.height);
              },
              onEnded: () {
                if (!mounted) return;
                setState(() => _playing = false);
              },
            ),
          if (_playing && canPlay && widget.onOpenFullscreen != null)
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: Colors.black.withValues(alpha: 0.42),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.onOpenFullscreen,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      LucideIcons.maximize_2,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          if (showSpinner) ...[
            ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
            Center(
              child: SizedBox(
                width: 52,
                height: 52,
                child: CircularProgressIndicator(
                  value: () {
                    final p = widget.attachment['download_progress'];
                    if (p is num && p > 0) return p.toDouble().clamp(0.0, 1.0);
                    return null;
                  }(),
                  strokeWidth: 3.5,
                  color: Colors.white,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
          ] else if (!_playing)
            const Center(child: GalleryVideoPlayBadge()),
        ],
      ),
    );

    return GestureDetector(
      onTap: _playing ? null : () => unawaited(_onTap()),
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
    required this.isMine,
    required this.textColor,
    required this.metaColor,
    this.messageMetadata = const {},
    this.uploadMessageId,
    this.onCancelUpload,
  });

  final int threadId;
  final Map<String, dynamic> attachment;
  final bool isMine;
  final Color textColor;
  final Color metaColor;
  final Map<String, dynamic> messageMetadata;
  final int? uploadMessageId;
  final VoidCallback? onCancelUpload;

  @override
  ConsumerState<_ChatFileAttachmentRow> createState() =>
      _ChatFileAttachmentRowState();
}

class _ChatFileAttachmentRowState extends ConsumerState<_ChatFileAttachmentRow> {
  String? _generatedPdfPreviewPath;
  bool _pdfPreviewTried = false;

  @override
  void initState() {
    super.initState();
    _scheduleAutoDownload();
    _schedulePdfPreview();
  }

  @override
  void didUpdateWidget(covariant _ChatFileAttachmentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment['id'] != widget.attachment['id'] ||
        oldWidget.attachment['local_device_path'] !=
            widget.attachment['local_device_path'] ||
        oldWidget.attachment['thumbnail_local_path'] !=
            widget.attachment['thumbnail_local_path']) {
      _generatedPdfPreviewPath = null;
      _pdfPreviewTried = false;
      _schedulePdfPreview();
    }
  }

  void _scheduleAutoDownload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final attachmentId = chatAsInt(widget.attachment['id']);
      if (attachmentId == null || attachmentId <= 0) return;
      if (widget.attachment['tdlib_file_id'] != null) return;
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

  void _schedulePdfPreview() {
    if (!_isPdf) return;
    if (_hasServerOrTdlibThumb) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pdfPreviewTried) return;
      _pdfPreviewTried = true;
      unawaited(_ensureLocalPdfPreview());
    });
  }

  bool get _isPdf => PdfPagePreview.looksLikePdf(
        filename: widget.attachment['filename']?.toString(),
        contentType: widget.attachment['content_type']?.toString(),
        path: galleryLocalDevicePath(widget.attachment),
      );

  bool get _hasServerOrTdlibThumb {
    final thumbPath =
        widget.attachment['thumbnail_local_path']?.toString().trim() ?? '';
    if (thumbPath.isNotEmpty) return true;
    if (isSafeUiPreviewBytes(widget.attachment['thumbnail_bytes'])) {
      return true;
    }
    final thumbUrl =
        widget.attachment['thumbnail_url']?.toString().trim() ?? '';
    return thumbUrl.isNotEmpty;
  }

  Future<void> _ensureLocalPdfPreview() async {
    final local = galleryLocalDevicePath(widget.attachment);
    if (local.isEmpty) return;
    final preview = await PdfPagePreview.firstPageJpegPath(local);
    if (!mounted || preview == null || preview.isEmpty) return;
    setState(() => _generatedPdfPreviewPath = preview);
  }

  Future<void> _openFile() async {
    var local = galleryLocalDevicePath(widget.attachment);

    final tdlibId = chatAsInt(widget.attachment['tdlib_file_id']);
    if ((local.isEmpty) && tdlibId != null && tdlibId > 0) {
      final path = await ref
          .read(telegramTdlibServiceProvider)
          .downloadFile(tdlibId);
      if (path != null && path.isNotEmpty) local = path;
    }

    if (local.isNotEmpty) {
      final result = await OpenFilex.open(local);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.message.isNotEmpty
                  ? result.message
                  : 'Не удалось открыть файл',
            ),
          ),
        );
      }
      return;
    }

    final url = widget.attachment['file_url']?.toString();
    if (url != null && url.isNotEmpty) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return;
    }
    final attachmentId = chatAsInt(widget.attachment['id']);
    if (attachmentId == null) return;
    final bytes =
        await ref.read(chatAttachmentDownloadManagerProvider).startDownload(
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
    if (galleryLocalDevicePath(widget.attachment).isNotEmpty) return true;
    if (widget.attachment['tdlib_file_id'] != null) return true;
    return ChatMediaAutoDownloadPolicy.isLocallyAvailable(
          threadId: widget.threadId,
          attachment: widget.attachment,
        ) ||
        ChatMediaAutoDownloadPolicy.hasRemoteContentUrl(
          attachment: widget.attachment,
        );
  }

  String get _filename {
    final raw = widget.attachment['filename']?.toString().trim();
    if (raw == null || raw.isEmpty) return 'Файл';
    return raw;
  }

  String get _extension {
    final name = _filename;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) return 'FILE';
    final ext = name.substring(dot + 1).toUpperCase();
    if (ext.length > 4) return ext.substring(0, 4);
    return ext;
  }

  Color get _badgeColor {
    switch (_extension) {
      case 'PDF':
        return const Color(0xFFE53935);
      case 'DOC':
      case 'DOCX':
      case 'ODT':
        return const Color(0xFF1E88E5);
      case 'XLS':
      case 'XLSX':
      case 'CSV':
        return const Color(0xFF43A047);
      case 'PPT':
      case 'PPTX':
        return const Color(0xFFFB8C00);
      case 'ZIP':
      case 'RAR':
      case '7Z':
        return const Color(0xFF8E24AA);
      case 'TXT':
      case 'MD':
        return const Color(0xFF546E7A);
      case 'APK':
        return const Color(0xFF00897B);
      default:
        return widget.isMine
            ? const Color(0xFF90CAF9)
            : const Color(0xFF5C6BC0);
    }
  }

  int? get _sizeBytes {
    final raw = widget.attachment['size_bytes'] ??
        widget.attachment['size'] ??
        widget.attachment['file_size'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  String? get _formattedSize {
    final bytes = _sizeBytes;
    if (bytes == null || bytes <= 0) return null;
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) {
      final kb = bytes / 1024;
      return '${kb < 10 ? kb.toStringAsFixed(1) : kb.toStringAsFixed(0)} КБ';
    }
    final mb = bytes / (1024 * 1024);
    return '${mb < 10 ? mb.toStringAsFixed(1) : mb.toStringAsFixed(0)} МБ';
  }

  String get _subtitle {
    final parts = <String>[_extension == 'FILE' ? 'Файл' : _extension];
    final size = _formattedSize;
    if (size != null) parts.add(size);
    return parts.join(' · ');
  }

  Widget? _previewImage() {
    final generated = _generatedPdfPreviewPath;
    if (generated != null && generated.isNotEmpty) {
      return Image.file(
        File(generated),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    final thumbPath =
        widget.attachment['thumbnail_local_path']?.toString().trim() ?? '';
    if (thumbPath.isNotEmpty) {
      return Image.file(
        File(thumbPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    final bytes = widget.attachment['thumbnail_bytes'];
    if (isSafeUiPreviewBytes(bytes)) {
      final raw = bytes is Uint8List ? bytes : Uint8List.fromList(bytes as List<int>);
      return Image.memory(
        raw,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    final thumbUrl =
        widget.attachment['thumbnail_url']?.toString().trim() ?? '';
    if (thumbUrl.isNotEmpty) {
      return Image.network(
        thumbUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return null;
  }

  Widget _extensionBadge({double size = 48}) {
    final badgeFg = _badgeColor.computeLuminance() > 0.55
        ? const Color(0xFF1A237E)
        : Colors.white;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _badgeColor,
        borderRadius: BorderRadius.circular(size > 56 ? 10 : 12),
      ),
      alignment: Alignment.center,
      child: Text(
        _extension,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: badgeFg,
          fontSize: _extension.length > 3 ? 10 : 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
          height: 1,
        ),
      ),
    );
  }

  Widget _metaColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _filename,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: widget.textColor,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          _subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: widget.metaColor,
            fontSize: 12,
            height: 1.15,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _isPdf ? _previewImage() : null;
    final showPdfCard = _isPdf;

    return ChatMediaTransferOverlay(
      threadId: widget.threadId,
      attachment: widget.attachment,
      uploadMessageId: widget.uploadMessageId,
      onCancelUpload: widget.onCancelUpload,
      onDownloadTap: _openFile,
      showManualDownload: !_skipDownloadOverlay(),
      child: InkWell(
        onTap: _openFile,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 180,
            maxWidth: showPdfCard ? 260 : 280,
          ),
          child: showPdfCard
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: AspectRatio(
                        aspectRatio: 3 / 4,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(color: Colors.grey.shade200),
                            if (preview != null) preview,
                            if (preview == null)
                              Center(child: _extensionBadge(size: 56)),
                            if (preview != null)
                              Positioned(
                                left: 8,
                                bottom: 8,
                                child: _extensionBadge(size: 36),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _metaColumn(),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _extensionBadge(),
                    const SizedBox(width: 10),
                    Expanded(child: _metaColumn()),
                  ],
                ),
        ),
      ),
    );
  }
}


