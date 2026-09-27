import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// Линия «Непрочитанные сообщения» между прочитанным хвостом и новыми.
///
/// Стиль ближе к Telegram: full-width soft primary bar + label.
class ChatUnreadSeparator extends StatelessWidget {
  const ChatUnreadSeparator({
    super.key,
    this.label = 'Непрочитанные сообщения',
    this.showChevron = false,
  });

  final String label;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bg = cs.primary.withValues(alpha: 0.12);
    final fg = cs.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ColoredBox(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
              if (showChevron)
                Icon(
                  LucideIcons.chevron_down,
                  size: 16,
                  color: fg.withValues(alpha: 0.85),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
