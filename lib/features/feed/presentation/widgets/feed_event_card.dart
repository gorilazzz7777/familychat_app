import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../chat/presentation/widgets/chat_network_image.dart';
import '../../../profile/presentation/media_engagement_inline.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';

class FeedEventCard extends StatelessWidget {
  const FeedEventCard({
    super.key,
    required this.event,
    required this.onOpenSource,
    this.onOpenMedia,
  });

  final Map<String, dynamic> event;
  final VoidCallback onOpenSource;
  final void Function(Map<String, dynamic> photo)? onOpenMedia;

  Map<String, dynamic> get _actor => (event['actor'] as Map<String, dynamic>?) ?? {};
  Map<String, dynamic> get _payload => (event['payload'] as Map<String, dynamic>?) ?? {};

  String get _kind => event['kind']?.toString() ?? '';

  String _titleText() {
    final name = _actor['name']?.toString() ?? 'Участник';
    return switch (_kind) {
      'message_sent' => '$name написал(а) в чате',
      'photo_uploaded' => '$name добавил(а) фото',
      'photo_added_to_album' => '$name добавил(а) фото в альбом',
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
    return {
      ...att,
      if (tid != null) 'thread_id': tid,
    };
  }

  Map<String, dynamic>? _singlePhoto() {
    final id = _payload['attachment_id'];
    final threadId = _payloadThreadId();
    if (id == null || threadId == null) return null;
    return {
      'id': id,
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
        .where((att) => att['thread_id'] != null)
        .toList();
  }

  int? _attachmentIdForEngagement(Map<String, dynamic> photo) {
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final createdAt = DateTime.tryParse(event['created_at']?.toString() ?? '');
    final timeText = createdAt != null
        ? DateFormat('d MMM, HH:mm', 'ru').format(createdAt.toLocal())
        : '';
    final preview = _bodyPreview();
    final where = _whereText();
    final primaryPhoto = _primaryPhoto();
    final galleryAttachments = primaryPhoto == null ? _galleryAttachments() : <Map<String, dynamic>>[];

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
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
                  onPressed: onOpenSource,
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
            if (galleryAttachments.isNotEmpty) ...[
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
                      onTap: () => onOpenMedia?.call(att),
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
                onTap: () => onOpenMedia?.call(primaryPhoto),
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
    );
  }
}
