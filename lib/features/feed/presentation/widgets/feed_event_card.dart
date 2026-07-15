import 'package:flutter/material.dart';

import '../../../../core/i18n/gender_verbs.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';
import 'feed_birthday_event_card.dart';
import 'feed_holiday_event_card.dart';
import 'feed_event_action_bar.dart';
import 'feed_expandable_caption.dart';
import 'feed_event_media_block.dart';

class FeedEventCard extends StatefulWidget {
  const FeedEventCard({
    super.key,
    required this.event,
    required this.onOpenSource,
    this.onOpenProfile,
    this.onOpenMedia,
    this.onOpenPhotoBatch,
  });

  final Map<String, dynamic> event;
  final VoidCallback onOpenSource;
  final VoidCallback? onOpenProfile;
  final void Function(Map<String, dynamic> photo)? onOpenMedia;
  final void Function(Map<String, dynamic> event, {int initialIndex})? onOpenPhotoBatch;

  @override
  State<FeedEventCard> createState() => _FeedEventCardState();
}

class _FeedEventCardState extends State<FeedEventCard> {
  int _batchIndex = 0;

  Map<String, dynamic> get _event => widget.event;
  Map<String, dynamic> get _actor => (_event['actor'] as Map<String, dynamic>?) ?? {};
  Map<String, dynamic> get _payload => (_event['payload'] as Map<String, dynamic>?) ?? {};
  String get _kind => _event['kind']?.toString() ?? '';

  bool get _isBirthdayEvent =>
      _kind == 'calendar_event' && _payload['event_kind']?.toString() == 'birthday';

  bool get _isHolidayEvent =>
      _kind == 'calendar_event' && _payload['event_kind']?.toString() == 'holiday';

  String _honoreeName() {
    final fromPayload = _payload['person_name']?.toString().trim();
    if (fromPayload != null && fromPayload.isNotEmpty) return fromPayload;
    final title = _payload['title']?.toString() ?? '';
    final parts = title.split('—');
    if (parts.length > 1) return parts.last.trim();
    return _actor['name']?.toString() ?? 'Именинник';
  }

  String _titleText() {
    final name = _actor['name']?.toString() ?? 'Участник';
    if (_kind == 'calendar_event') {
      return _payload['title']?.toString() ?? 'Событие календаря';
    }
    final photoCount = _kind == 'photo_batch_uploaded'
        ? (_payload['photo_count'] is int
            ? _payload['photo_count'] as int
            : int.tryParse('${_payload['photo_count']}') ?? _batchPhotos().length)
        : null;
    final othersRaw = _payload['others_count'];
    final othersCount = othersRaw is int
        ? othersRaw
        : int.tryParse('$othersRaw');
    return feedEventTitle(
      kind: _kind,
      actorName: name,
      gender: actorGender(_actor),
      joinedName: _payload['name']?.toString(),
      photoCount: photoCount,
      othersCount: othersCount,
    );
  }

  String _navigateTooltip() {
    return switch (_kind) {
      'message_sent' => 'Открыть чат',
      'photo_added_to_album' => 'Открыть альбом',
      'photo_batch_uploaded' => 'Открыть альбом',
      'photo_uploaded' => 'Открыть галерею',
      'media_liked' || 'media_commented' => 'Открыть фото',
      'calendar_event' => 'Открыть календарь',
      'member_joined' || 'profile_updated' => 'Открыть профиль',
      _ => 'Перейти',
    };
  }

  String? _captionText() {
    final caption = _payload['caption']?.toString().trim() ?? '';
    if (caption.isEmpty) return null;
    if (_kind == 'photo_uploaded' ||
        _kind == 'photo_added_to_album' ||
        _kind == 'photo_batch_uploaded') {
      return caption;
    }
    return null;
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

  List<Map<String, dynamic>> _displayPhotos() {
    if (_kind == 'photo_batch_uploaded') {
      return _batchPhotos();
    }
    final single = _singlePhoto();
    if (single != null) return [single];

    if (_kind == 'message_sent') {
      final images = _attachments()
          .where(_isImageAttachment)
          .map((att) => _normalizePhoto(att))
          .where((att) => att['thread_id'] != null && att['id'] != null)
          .toList();
      if (images.isNotEmpty) return images;
    }
    return const [];
  }

  int? _attachmentIdForEngagement(Map<String, dynamic>? photo) {
    if (photo == null) return null;
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  int? _currentEngagementAttachmentId(List<Map<String, dynamic>> photos) {
    if (photos.isEmpty) return null;
    final index = _kind == 'photo_batch_uploaded'
        ? _batchIndex.clamp(0, photos.length - 1)
        : 0;
    return _attachmentIdForEngagement(photos[index]);
  }

  void _openPhoto(int index, List<Map<String, dynamic>> photos) {
    if (widget.onOpenPhotoBatch != null && _kind == 'photo_batch_uploaded') {
      widget.onOpenPhotoBatch!(widget.event, initialIndex: index);
      return;
    }
    if (photos.isEmpty) return;
    final photo = photos[index.clamp(0, photos.length - 1)];
    widget.onOpenMedia?.call(photo);
  }

  @override
  Widget build(BuildContext context) {
    final createdAt = DateTime.tryParse(_event['created_at']?.toString() ?? '');

    if (_isBirthdayEvent) {
      return FeedBirthdayEventCard(
        honoreeName: _honoreeName(),
        honoreeAvatarUrl: _actor['avatar_url']?.toString(),
        eventDate: _payload['date']?.toString(),
        createdAt: createdAt,
        onOpenChat: widget.onOpenSource,
        onOpenProfile: widget.onOpenProfile,
      );
    }

    if (_isHolidayEvent) {
      final description = _payload['description']?.toString().trim() ?? '';
      return FeedHolidayEventCard(
        title: _payload['title']?.toString() ?? 'Праздник',
        description: description.isNotEmpty
            ? description
            : 'Сегодня в семейном календаре отмечен праздник.',
        holidayCode: _payload['code']?.toString() ?? '',
        eventDate: _payload['date']?.toString(),
        createdAt: createdAt,
        onOpenCalendar: widget.onOpenSource,
      );
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final preview = _bodyPreview();
    final caption = _captionText();
    final photos = _displayPhotos();
    final hasMedia = photos.isNotEmpty;
    final engagementAttachmentId = _currentEngagementAttachmentId(photos);

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onOpenProfile,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ChatAvatar(
                      name: _actor['name']?.toString() ?? '?',
                      avatarUrl: _actor['avatar_url']?.toString(),
                      radius: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _titleText(),
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (preview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                preview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          if (hasMedia)
            FeedEventMediaBlock(
              photos: photos,
              onPhotoTap: (index) => _openPhoto(index, photos),
              onIndexChanged: _kind == 'photo_batch_uploaded'
                  ? (index) => setState(() => _batchIndex = index)
                  : null,
            ),
          if (caption != null) FeedExpandableCaption(text: caption),
          FeedEventActionBar(
            key: ValueKey<int?>(engagementAttachmentId),
            attachmentId: engagementAttachmentId,
            createdAt: createdAt,
            onNavigate: widget.onOpenSource,
            navigateTooltip: _navigateTooltip(),
          ),
        ],
      ),
    );
  }
}
