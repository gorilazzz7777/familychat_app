import 'package:flutter/material.dart';

import '../../data/chat_voice_utils.dart';

class ChatVoiceRecordingBanner extends StatelessWidget {
  const ChatVoiceRecordingBanner({
    super.key,
    required this.durationMs,
  });

  final int durationMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatVoiceDuration(durationMs),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Отпустите для отправки',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
