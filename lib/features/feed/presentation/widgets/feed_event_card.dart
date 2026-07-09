import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../chat/presentation/widgets/chat_network_image.dart';
import '../../../profile/presentation/media_engagement_inline.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';

class FeedEventCard extends StatefulWidget {
  const FeedEventCard({
    super.key,
    required this.event,
    required this.onOpenSource,
    this.onOpenMedia,
    this.onOpenPhotoBatch,
  });

  final Map<String, dynamic> event;
  final VoidCallback onOpenSource;
  final void Function(Map<String, dynamic> photo)? onOpenMedia;
  final void Function(Map<String, dynamic> event, {int initialIndex})? onOpenPhotoBatch;

  @override
  State<FeedEventCard> createState() => _FeedEventCardState();
}

class _FeedEventCardState extends State<FeedEventCard> {
  late final PageController _batchPageController;
  int _batchIndex = 0;

  Map<String, dynamic> get _event => widget.event;
  Map<String, dynamic> get _actor => (_event['actor'] as Map<String, dynamic>?) ?? {};
  Map<String, dynamic> get _payload => (_event['payload'] as Map<String, dynamic>?) ?? {};
  String get _kind => _event['kind']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _batchPageController = PageController();
  }

  @override
  void dispose() {
    _batchPageController.dispose();
    super.dispose();
  }

  String _titleText() {
    final name = _actor['name']?.toString() ?? 'Участник';
    return switch (_kind) {
      'message_sent' => '$name написал(а) в чате',
      'photo_uploaded' => '$name добавил(а) фото',
      'photo_added_to_album' => '$name добавил(а) фото в альбом',
      'photo_batch_uploaded' => () {
        final count = _payload['photo_count'] is int
            ? _payload['photo_count'] as int
            : int.tryParse('${_payload['photo_count']}') ??
                _batchPhotos().length;
        return '$name добавил $count фото';
      }(),
      'media_liked' => '$name лайкнул(а) фото',
      'media_commented' => '$name прокомментировал(а) фото',
      'calendar_event' => _payload['title']?.toString() ?? 'Событие календаря',
      'member_joined' => '${_payload['name'] ?? name} присоединился(ась) к семье',
      'profile_updated' => '$name обновил(а) профиль',
      _ => 'Событие',
    };
  }

  String _whereText() {
    return switch (_kind) {
      'message_sent' => _payload['thread_title']?.toString() ?? 'Чат',
      'photo_added_to_album' => _payload['album_title']?.toString() ?? 'Альбом',
      'photo_batch_uploaded' => _payload['mixed_destinations'] == true
          ? ''
          : (_payload['album_title']?.toString() ??
              _payload['destination_label']?.toString() ??
              ''),
      'calendar_event' => 'Календарь',
      'photo_uploaded' || 'media_liked' || 'media_commented' => 'Галерея',
      _ => '',
    };
  }

  String _bodyPreview() {
    if (_kind == 'message_sent') {
      return _payload['body_preview']?.toString() ?? '';
    }
    if (_kind == 'profile_updated') {
      final fields = (_payload['changed_fields'] as List<dynamic>? ?? []).join(', ');
      return fields.isEmpty ? '' : 'Изменено: $fields';
    }
    return '';
  }

  List<Map<String, dynamic>> _attachments() {
    return (_payload['attachments'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  }

  int? _parseThreadId(Object? value) {
    if (value is int) return value;
    return int.tryParse('$value');
  }

  int? _payloadThreadId() => _parseThreadId(_payload['thread_id']);

  bool _isImageAttachment(Map<String, dynamic> att) {
    final kind = att['kind']?.toString();
    if (kind == 'image') return true;
    final name = att['filename']?.toString().toLowerCase() ?? '';
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp') ||
        name.endsWith('.heic');
  }

  Map<String, dynamic> _normalizePhoto(Map<String, dynamic> att, {int? threadId}) {
    final tid = _parseThreadId(att['thread_id']) ?? threadId ?? _payloadThreadId();
    final rawId = att['id'] ?? att['attachment_id'];
    final id = rawId is int ? rawId : int.tryParse('$rawId');
    return {
      ...att,
      if (id != null) 'id': id,
      if (tid != null) 'thread_id': tid,
    };
  }

  List<Map<String, dynamic>> _batchPhotos() {
    return _attachments()
        .where(_isImageAttachment)
        .map((att) => _normalizePhoto(att))
        .where((att) => att['thread_id'] != null && att['id'] != null)
        .toList();
  }

  Map<String, dynamic>? _singlePhoto() {
    final id = _payload['attachment_id'];
    final threadId = _payloadThreadId();
    if (id == null || threadId == null) return null;
    return {
      'id': id is int ? id : int.tryParse('$id'),
      'thread_id': threadId,
      'file_url': _payload['file_url'],
      'filename': _payload['filename'],
    };
  }

  Map<String, dynamic>? _primaryPhoto() {
    final single = _singlePhoto();
    if (single != null) return single;

    if (_kind == 'message_sent') {
      final images = _attachments().where(_isImageAttachment).toList();
      if (images.length == 1) {
        final photo = _normalizePhoto(images.first);
        if (photo['thread_id'] == null || photo['id'] == null) return null;
        return photo;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _galleryAttachments() {
    final payloadThreadId = _payloadThreadId();
    return _attachments()
        .where(_isImageAttachment)
        .map((att) => _normalizePhoto(att, threadId: payloadThreadId))
        .where((att) => att['thread_id'] != null && att['id'] != null)
        .toList();
  }

  int? _attachmentIdForEngagement(Map<String, dynamic> photo) {
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  void _openBatchPhoto({int initialIndex = 0}) {
    if (widget.onOpenPhotoBatch != null) {
      widget.onOpenPhotoBatch!(widget.event, initialIndex: initialIndex);
      return;
    }
    final photos = _batchPhotos();
    if (photos.isEmpty) return;
    final photo = photos[initialIndex.clamp(0, photos.length - 1)];
    widget.onOpenMedia?.call(photo);
  }

  Widget _buildBatchCarousel(ThemeData theme) {
    final photos = _batchPhotos();
    if (photos.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 220,
            child: PageView.builder(
              controller: _batchPageController,
              itemCount: photos.length,
              onPageChanged: (index) => setState(() => _batchIndex = index),
              itemBuilder: (_, index) {
                final photo = photos[index];
                return GestureDetector(
                  onTap: () => _openBatchPhoto(initialIndex: index),
                  child: ChatNetworkImage(
                    threadId: photo['thread_id'] as int,
                    attachment: photo,
                    width: double.infinity,
                    height: 220,
                    fit: BoxFit.cover,
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '${_batchIndex + 1} / ${photos.length}',
              style: theme.textTheme.labelMedium,
            ),
            const Spacer(),
            if (photos.length > 1) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _batchIndex > 0
                    ? () => _batchPageController.previousPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _batchIndex < photos.length - 1
                    ? () => _batchPageController.nextPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        )
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ],
        ),
        if (_attachmentIdForEngagement(photos[_batchIndex]) case final attachmentId?)
          MediaEngagementInline(
            key: ValueKey<int>(attachmentId),
            attachmentId: attachmentId,
            maxComments: 4,
            dense: true,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final createdAt = DateTime.tryParse(_event['created_at']?.toString() ?? '');
    final timeText = createdAt != null
        ? DateFormat('d MMM, HH:mm', 'ru').format(createdAt.toLocal())
        : '';
    final preview = _bodyPreview();
    final where = _whereText();
    final primaryPhoto = _primaryPhoto();
    final galleryAttachments = primaryPhoto == null ? _galleryAttachments() : <Map<String, dynamic>>[];
    final isBatch = _kind == 'photo_batch_uploaded';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: isBatch ? () => _openBatchPhoto(initialIndex: _batchIndex) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ChatAvatar(
                    name: _actor['name']?.toString() ?? '?',
                    avatarUrl: _actor['avatar_url']?.toString(),
                    radius: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_titleText(), style: theme.textTheme.titleSmall),
                        if (where.isNotEmpty)
                          Text(
                            where,
                            style: theme.textTheme.bodySmall?.copyWith(color: cs.primary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Перейти',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: widget.onOpenSource,
                    icon: Icon(Icons.north_east, size: 20, color: cs.primary),
                  ),
                  const SizedBox(width: 4),
                  Text(timeText, style: theme.textTheme.labelSmall),
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (isBatch)
                _buildBatchCarousel(theme)
              else if (galleryAttachments.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 88,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: galleryAttachments.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final att = galleryAttachments[i];
                      final threadId = att['thread_id'] as int;
                      return GestureDetector(
                        onTap: () => widget.onOpenMedia?.call(att),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ChatNetworkImage(
                            threadId: threadId,
                            attachment: att,
                            width: 88,
                            height: 88,
                            fit: BoxFit.cover,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ] else if (primaryPhoto != null) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () => widget.onOpenMedia?.call(primaryPhoto),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ChatNetworkImage(
                      threadId: primaryPhoto['thread_id'] as int,
                      attachment: primaryPhoto,
                      height: 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                if (_attachmentIdForEngagement(primaryPhoto) case final attachmentId?)
                  MediaEngagementInline(
                    attachmentId: attachmentId,
                    maxComments: 4,
                    dense: true,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
