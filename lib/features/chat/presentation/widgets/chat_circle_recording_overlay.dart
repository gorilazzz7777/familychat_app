import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/chat_voice_utils.dart';
import 'chat_compose_circle_button.dart';
import 'chat_video_circle_session.dart';

/// Оверлей записи кружка поверх чата (превью + прогресс).
class ChatCircleRecordingOverlay extends StatelessWidget {
  const ChatCircleRecordingOverlay({
    super.key,
    required this.session,
    required this.durationMs,
    required this.locked,
    this.onCancel,
    this.onSend,
  });

  final ChatVideoCircleSession session;
  final int durationMs;
  final bool locked;
  final VoidCallback? onCancel;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final size = math.min(MediaQuery.sizeOf(context).width * 0.72, 300.0);
    final progress =
        (durationMs / ChatVideoCircleSession.maxMs).clamp(0.0, 1.0);

    return Material(
      color: Colors.black.withValues(alpha: locked ? 0.55 : 0.35),
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            IgnorePointer(
              child: ChatVideoCirclePreview(
                session: session,
                size: size,
                progress: progress,
              ),
            ),
            const SizedBox(height: 24),
            if (!locked)
              IgnorePointer(
                child: Text(
                  'Удерживайте · свайп — замок · влево — отмена',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ),
            if (locked)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
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
                        color: Colors.white,
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
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ),
                    ChatComposeCircleButton(
                      tooltip: 'Отправить',
                      icon: Icons.send_rounded,
                      iconColor: cs.onPrimary,
                      backgroundColor: cs.primary,
                      onTap: onSend,
                    ),
                  ],
                ),
              )
            else
              const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}
