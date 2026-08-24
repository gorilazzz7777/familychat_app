import 'package:flutter/material.dart';

/// Статус своего сообщения: отправка / отправлено / прочитано.
class ChatMessageReadStatusIcon extends StatelessWidget {
  const ChatMessageReadStatusIcon({
    super.key,
    required this.status,
    required this.color,
    this.size = 16,
  });

  final String status;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (status == 'sending' || status == 'queued') {
      return Semantics(
        label: 'Отправляется',
        child: Tooltip(
          message: 'Отправляется',
          child: Icon(Icons.schedule, size: size, color: color),
        ),
      );
    }

    if (status == 'scheduled') {
      return Semantics(
        label: 'Отложенная отправка',
        child: Tooltip(
          message: 'Отложенная отправка',
          child: Icon(Icons.schedule_send, size: size, color: color),
        ),
      );
    }

    if (status == 'failed') {
      return Semantics(
        label: 'Не отправлено. Нажмите, чтобы повторить',
        child: Tooltip(
          message: 'Не отправлено. Нажмите, чтобы повторить',
          child: Icon(
            Icons.refresh,
            size: size,
            color: color.withValues(alpha: 0.95),
          ),
        ),
      );
    }

    final isRead = status == 'read';
    final label = isRead ? 'Прочитано' : 'Отправлено';
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: Icon(
          isRead ? Icons.done_all : Icons.done,
          size: size,
          color: isRead ? const Color(0xFF4FC3F7) : color,
        ),
      ),
    );
  }
}
