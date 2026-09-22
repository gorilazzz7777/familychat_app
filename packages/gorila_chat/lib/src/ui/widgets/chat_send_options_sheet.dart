import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../contract/chat_send_options.dart';

/// Меню режимов отправки по долгому нажатию на «Отправить».
class ChatSendOptionsSheet {
  static Future<ChatSendOptions?> show(
    BuildContext context, {
    bool showSilent = true,
    bool showSchedule = true,
    bool showAiAssist = false,
    bool showDeliveryChannel = false,
    @Deprecated('Use showDeliveryChannel') bool showDeliverToTelegram = false,
    ChatDeliveryChannel initialChannel = ChatDeliveryChannel.auto,
  }) {
    final showChannel = showDeliveryChannel || showDeliverToTelegram;
    return showModalBottomSheet<ChatSendOptions>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _ChatSendOptionsBody(
        showSilent: showSilent,
        showSchedule: showSchedule,
        showAiAssist: showAiAssist,
        showDeliveryChannel: showChannel,
        initialChannel: initialChannel,
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

class _ChatSendOptionsBody extends StatefulWidget {
  const _ChatSendOptionsBody({
    required this.showSilent,
    required this.showSchedule,
    required this.showAiAssist,
    required this.showDeliveryChannel,
    required this.initialChannel,
  });

  final bool showSilent;
  final bool showSchedule;
  final bool showAiAssist;
  final bool showDeliveryChannel;
  final ChatDeliveryChannel initialChannel;

  @override
  State<_ChatSendOptionsBody> createState() => _ChatSendOptionsBodyState();
}

class _ChatSendOptionsBodyState extends State<_ChatSendOptionsBody> {
  late ChatDeliveryChannel _channel = widget.initialChannel;

  Widget _channelLogo(String asset) {
    return Image.asset(
      asset,
      width: 22,
      height: 22,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => const Icon(LucideIcons.circle, size: 18),
    );
  }

  ChatSendOptions _withChannel({
    bool silent = false,
    DateTime? scheduledAt,
    bool aiAssist = false,
    bool preferenceOnly = false,
  }) {
    return ChatSendOptions(
      silent: silent,
      scheduledAt: scheduledAt,
      aiAssist: aiAssist,
      deliveryChannel: _channel,
      preferenceOnly: preferenceOnly,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showDeliveryChannel) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Куда отправить',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<ChatDeliveryChannel>(
                      segments: [
                        const ButtonSegment(
                          value: ChatDeliveryChannel.auto,
                          icon: Icon(LucideIcons.sparkles, size: 18),
                          label: Text('Авто'),
                          tooltip: 'Авто',
                        ),
                        ButtonSegment(
                          value: ChatDeliveryChannel.familychat,
                          icon: _channelLogo('assets/logo/logo.png'),
                          tooltip: 'Family Space',
                        ),
                        ButtonSegment(
                          value: ChatDeliveryChannel.telegram,
                          icon: _channelLogo('assets/logo/tg.png'),
                          tooltip: 'Telegram',
                        ),
                      ],
                      selected: {_channel},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) {
                        final channel = s.first;
                        setState(() => _channel = channel);
                        Navigator.pop(
                          context,
                          ChatSendOptions(
                            deliveryChannel: channel,
                            preferenceOnly: true,
                          ),
                        );
                      },
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      switch (_channel) {
                        ChatDeliveryChannel.auto =>
                          'Авто: если последний ответ был в Telegram — туда',
                        ChatDeliveryChannel.familychat =>
                          'Только Family Space, без Telegram',
                        ChatDeliveryChannel.telegram =>
                          'Доставить в Telegram от вашего имени',
                      },
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
            if (widget.showSilent)
              ListTile(
                dense: true,
                leading: const Icon(LucideIcons.bell_off),
                title: const Text('Отправить без звука'),
                subtitle: const Text(
                  'Получатель увидит сообщение без звука уведомления',
                ),
                onTap: () => Navigator.pop(
                  context,
                  _withChannel(silent: true),
                ),
              ),
            if (widget.showSchedule)
              ListTile(
                dense: true,
                leading: const Icon(LucideIcons.calendar_clock),
                title: const Text('Отложить отправку'),
                subtitle: const Text('Выбрать дату и время'),
                onTap: () async {
                  final scheduledAt =
                      await ChatSendOptionsSheet._pickSchedule(context);
                  if (!context.mounted || scheduledAt == null) return;
                  Navigator.pop(
                    context,
                    _withChannel(scheduledAt: scheduledAt),
                  );
                },
              ),
            if (widget.showAiAssist)
              ListTile(
                dense: true,
                leading: const Icon(LucideIcons.sparkles),
                title: const Text('С помощью AI'),
                subtitle: const Text('Составить текст сообщения по заданию'),
                onTap: () => Navigator.pop(
                  context,
                  _withChannel(aiAssist: true),
                ),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
