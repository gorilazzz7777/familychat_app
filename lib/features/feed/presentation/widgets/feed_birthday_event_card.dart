import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../profile/presentation/widgets/chat_avatar.dart';
import 'feed_event_date_format.dart';

/// Карточка дня рождения в ленте — с поздравительным текстом и призывом к действию.
class FeedBirthdayEventCard extends StatelessWidget {
  const FeedBirthdayEventCard({
    super.key,
    required this.honoreeName,
    this.honoreeAvatarUrl,
    this.eventDate,
    this.createdAt,
    required this.onOpenChat,
    this.onOpenProfile,
  });

  final String honoreeName;
  final String? honoreeAvatarUrl;
  final String? eventDate;
  final DateTime? createdAt;
  final VoidCallback onOpenChat;
  final VoidCallback? onOpenProfile;

  String get _dateLabel {
    final parsed = DateTime.tryParse(eventDate ?? '');
    if (parsed == null) return 'Сегодня';
    final formatted = DateFormat('d MMMM', 'ru').format(parsed);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(parsed.year, parsed.month, parsed.day);
    if (day == today) return 'Сегодня, $formatted';
    return formatted;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = cs.tertiary;
    final accentContainer = cs.tertiaryContainer;
    final onAccent = cs.onTertiaryContainer;
    final dateText =
        createdAt != null ? formatFeedEventDate(createdAt!) : '';

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
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accentContainer,
                  accentContainer.withValues(alpha: 0.55),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.cake_rounded, color: accent, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'День рождения',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: onAccent,
                    ),
                  ),
                ),
                Text(
                  _dateLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: onAccent.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onOpenProfile,
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  children: [
                    ChatAvatar(
                      name: honoreeName,
                      avatarUrl: honoreeAvatarUrl,
                      radius: 36,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      honoreeName,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Празднует день рождения',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.celebration_outlined,
                        size: 20,
                        color: accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'У $honoreeName сегодня особенный день!',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Поздравьте в чате подготовки — там уже собираются '
                    'пожелания от семьи. Нажмите кнопку ниже, чтобы '
                    'написать поздравление.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: FilledButton.icon(
              onPressed: onOpenChat,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Поздравить в чате'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Открыть день рождения',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: onOpenChat,
                  icon: Icon(Icons.open_in_new, size: 22, color: cs.primary),
                ),
                const Spacer(),
                if (dateText.isNotEmpty)
                  Text(
                    dateText,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
