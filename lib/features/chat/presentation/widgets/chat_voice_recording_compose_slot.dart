import 'package:flutter/material.dart';

import '../../data/chat_voice_utils.dart';

enum ChatComposeRecordKind { voice, circle }

/// Индикатор записи в строке ввода (hold или lock).
class ChatVoiceRecordingComposeSlot extends StatelessWidget {
  const ChatVoiceRecordingComposeSlot({
    super.key,
    required this.durationMs,
    required this.willCancel,
    this.locked = false,
    this.kind = ChatComposeRecordKind.voice,
    this.onCancel,
  });

  final int durationMs;
  final bool willCancel;
  final bool locked;
  final ChatComposeRecordKind kind;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = willCancel ? cs.error : cs.error;

    if (locked) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: cs.error,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatVoiceDuration(durationMs),
              style: theme.textTheme.titleMedium?.copyWith(
                color: cs.error,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: onCancel,
                child: Text(
                  'ОТМЕНА',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatVoiceDuration(durationMs),
            style: theme.textTheme.titleMedium?.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              willCancel
                  ? 'Отпустите для отмены'
                  : (kind == ChatComposeRecordKind.circle
                      ? '‹ Влево — отмена · свайп — замок'
                      : '‹ Влево — отмена · свайп — замок'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: willCancel ? cs.error : cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
