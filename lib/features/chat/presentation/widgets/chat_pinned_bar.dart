import 'package:flutter/material.dart';

/// Панель закреплённых сообщений (как в Telegram): превью + листание по тапу.
class ChatPinnedBar extends StatelessWidget {
  const ChatPinnedBar({
    super.key,
    required this.message,
    required this.index,
    required this.total,
    required this.onTap,
    required this.onClose,
    this.previewText = '',
  });

  final Map<String, dynamic> message;
  final int index;
  final int total;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final String previewText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = total > 1
        ? 'Закреплённое сообщение ${index + 1}/$total'
        : 'Закреплённое сообщение';
    final preview = previewText.trim().isNotEmpty
        ? previewText.trim()
        : (message['body']?.toString().trim().isNotEmpty == true
            ? message['body'].toString().trim()
            : 'Сообщение');

    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              Container(
                width: 3,
                height: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 8),
                color: scheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.push_pin, size: 18, color: scheme.primary),
              if (total > 1) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.view_agenda_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
              IconButton(
                tooltip: 'Открепить',
                onPressed: onClose,
                icon: Icon(
                  Icons.close,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
