import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../chat/presentation/widgets/chat_network_image.dart';
import '../../../profile/presentation/media_engagement_sheet.dart';
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
    if (_kind == 'media_commented') {
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

  Map<String, dynamic>? _singlePhoto() {
    final id = _payload['attachment_id'];
    final threadId = _payload['thread_id'];
    if (id == null || threadId == null) return null;
    return {
      'id': id,
      'thread_id': threadId,
      'file_url': _payload['file_url'],
      'filename': _payload['filename'],
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final createdAt = DateTime.tryParse(event['created_at']?.toString() ?? '');
    final timeText = createdAt != null ? DateFormat('d MMM, HH:mm').format(createdAt.toLocal()) : '';
    final preview = _bodyPreview();
    final where = _whereText();
    final attachments = _attachments();
    final singlePhoto = _singlePhoto();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpenSource,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                          Text(where, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                      ],
                    ),
                  ),
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
              if (attachments.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 88,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: attachments.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final att = attachments[i];
                      final threadId = att['thread_id'] is int
                          ? att['thread_id'] as int
                          : int.tryParse('${att['thread_id']}');
                      if (threadId == null) return const SizedBox.shrink();
                      return GestureDetector(
                        onTap: () => onOpenMedia?.call({
                          ...att,
                          'thread_id': threadId,
                        }),
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
              ] else if (singlePhoto != null) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () => onOpenMedia?.call(singlePhoto),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ChatNetworkImage(
                      threadId: singlePhoto['thread_id'] as int,
                      attachment: singlePhoto,
                      height: 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _MediaActionsRow(photo: singlePhoto),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: onOpenSource, child: const Text('Открыть')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaActionsRow extends StatelessWidget {
  const _MediaActionsRow({required this.photo});

  final Map<String, dynamic> photo;

  @override
  Widget build(BuildContext context) {
    final attachmentId = photo['id'] is int ? photo['id'] as int : int.tryParse('${photo['id']}');
    if (attachmentId == null) return const SizedBox.shrink();
    return Row(
      children: [
        TextButton.icon(
          onPressed: () => MediaEngagementSheet.show(context, attachmentId: attachmentId),
          icon: const Icon(Icons.favorite_border, size: 18),
          label: const Text('Лайки'),
        ),
        TextButton.icon(
          onPressed: () => MediaEngagementSheet.show(context, attachmentId: attachmentId, focusComment: true),
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: const Text('Комментарии'),
        ),
      ],
    );
  }
}
