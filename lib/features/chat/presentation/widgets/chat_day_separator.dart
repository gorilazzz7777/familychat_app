import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Локальный календарный день сообщения (`created_at`).
DateTime? chatMessageLocalDay(Map<String, dynamic> message) {
  final created = DateTime.tryParse(message['created_at']?.toString() ?? '');
  if (created == null) return null;
  final local = created.toLocal();
  return DateTime(local.year, local.month, local.day);
}

bool chatSameCalendarDay(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final da = chatMessageLocalDay(a);
  final db = chatMessageLocalDay(b);
  if (da == null || db == null) return false;
  return da == db;
}

/// Подпись дня как в Telegram: «Сегодня» / «Вчера» / «14 августа».
String formatChatDayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  if (day == today) return 'Сегодня';
  if (day == yesterday) return 'Вчера';
  if (day.year == today.year) {
    return DateFormat('d MMMM', 'ru').format(day);
  }
  return DateFormat('d MMMM yyyy', 'ru').format(day);
}

/// Пилюля-разделитель дня (inline и sticky overlay).
class ChatDaySeparator extends StatelessWidget {
  const ChatDaySeparator({
    super.key,
    required this.label,
    this.compact = false,
  });

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: compact ? 6 : 10,
      ),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    height: 1.15,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
