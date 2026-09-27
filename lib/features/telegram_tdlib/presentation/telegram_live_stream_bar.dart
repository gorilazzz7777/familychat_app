import 'package:flutter/material.dart';

import '../telegram_tdlib_service.dart';

/// TG-style live stream strip: title + viewer count + «Вступить».
class TelegramLiveStreamBar extends StatelessWidget {
  const TelegramLiveStreamBar({
    super.key,
    required this.videoChat,
    required this.onJoin,
    this.joining = false,
  });

  final TdlibVideoChat videoChat;
  final VoidCallback onJoin;
  final bool joining;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const accent = Color(0xFF2AABEE);
    final title = videoChat.title.trim().isNotEmpty
        ? videoChat.title.trim()
        : 'Трансляция';

    return Material(
      color: accent.withValues(alpha: 0.12),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: joining ? null : onJoin,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        videoChat.viewerCountLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: joining ? null : onJoin,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: accent.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: joining
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Вступить',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
