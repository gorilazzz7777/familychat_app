import 'package:flutter/material.dart';

import '../../data/chat_voice_utils.dart';

/// Индикатор записи вместо поля «Сообщение...» (как в Telegram).
class ChatVoiceRecordingComposeSlot extends StatelessWidget {
  const ChatVoiceRecordingComposeSlot({
    super.key,
    required this.durationMs,
    required this.willCancel,
  });

  final int durationMs;
  final bool willCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = willCancel ? cs.error : cs.error;

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
                  : '‹ Влево — отмена',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: willCancel
                    ? cs.error
                    : cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
