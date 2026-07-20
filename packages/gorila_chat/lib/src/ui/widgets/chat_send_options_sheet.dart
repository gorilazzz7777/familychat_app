import 'package:flutter/material.dart';

import '../../contract/chat_send_options.dart';

/// Меню режимов отправки по долгому нажатию на «Отправить».
class ChatSendOptionsSheet {
  static Future<ChatSendOptions?> show(
    BuildContext context, {
    bool showSilent = true,
    bool showSchedule = true,
    bool showAiAssist = false,
  }) {
    return showModalBottomSheet<ChatSendOptions>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSilent)
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Отправить без звука'),
                subtitle: const Text(
                  'Получатель увидит сообщение без звука уведомления',
                ),
                onTap: () => Navigator.pop(
                  ctx,
                  const ChatSendOptions(silent: true),
                ),
              ),
            if (showSchedule)
              ListTile(
                leading: const Icon(Icons.schedule_send_outlined),
                title: const Text('Отложить отправку'),
                subtitle: const Text('Выбрать дату и время'),
                onTap: () async {
                  final scheduledAt = await _pickSchedule(ctx);
                  if (!ctx.mounted || scheduledAt == null) return;
                  Navigator.pop(ctx, ChatSendOptions(scheduledAt: scheduledAt));
                },
              ),
            if (showAiAssist)
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: const Text('С помощью AI'),
                subtitle: const Text('Составить текст сообщения по заданию'),
                onTap: () => Navigator.pop(ctx, ChatSendOptions.ai),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static Future<DateTime?> _pickSchedule(BuildContext context) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('ru'),
    );
    if (date == null || !context.mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
    );
    if (time == null) return null;

    final scheduled = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!scheduled.isAfter(now)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Выберите время в будущем')),
        );
      }
      return null;
    }
    return scheduled;
  }
}
