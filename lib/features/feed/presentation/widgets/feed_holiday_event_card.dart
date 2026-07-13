import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'feed_event_date_format.dart';

IconData feedHolidayIcon(String code) {
  return switch (code) {
    'new_year' || 'old_new_year' => Icons.auto_awesome_outlined,
    'christmas' || 'easter' => Icons.church_outlined,
    'valentine' || 'family_day' => Icons.favorite_outline,
    'defender_day' => Icons.military_tech_outlined,
    'womens_day' || 'mothers_day' => Icons.spa_outlined,
    'victory_day' || 'russia_day' || 'unity_day' => Icons.flag_outlined,
    'knowledge_day' || 'student_day' || 'teachers_day' => Icons.school_outlined,
    'programmer_day' => Icons.code_outlined,
    'cosmonautics_day' => Icons.rocket_launch_outlined,
    'medical_worker_day' => Icons.local_hospital_outlined,
    'grandparents_day' => Icons.elderly_outlined,
    'siblings_day' => Icons.groups_2_outlined,
    'labor_day' => Icons.park_outlined,
    'april_fools' => Icons.sentiment_very_satisfied_outlined,
    _ => Icons.event_outlined,
  };
}

/// Карточка праздника в ленте — нейтральная напоминалка из семейного календаря.
class FeedHolidayEventCard extends StatelessWidget {
  const FeedHolidayEventCard({
    super.key,
    required this.title,
    required this.description,
    required this.holidayCode,
    this.eventDate,
    this.createdAt,
    required this.onOpenCalendar,
  });

  final String title;
  final String description;
  final String holidayCode;
  final String? eventDate;
  final DateTime? createdAt;
  final VoidCallback onOpenCalendar;

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
    final accent = cs.secondary;
    final accentContainer = cs.secondaryContainer;
    final onAccent = cs.onSecondaryContainer;
    final dateText =
        createdAt != null ? formatFeedEventDate(createdAt!) : '';
    final icon = feedHolidayIcon(holidayCode);

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
                Icon(icon, color: accent, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Праздник в календаре',
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
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: accentContainer.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 36, color: accent),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Семейный календарь',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
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
                        Icons.info_outline,
                        size: 20,
                        color: accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Напоминание о празднике',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    description,
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
              onPressed: onOpenCalendar,
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('Открыть в календаре'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Icon(Icons.event_note_outlined, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Без поздравлений — только напоминание',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
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
