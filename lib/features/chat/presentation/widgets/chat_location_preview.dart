import 'package:flutter/material.dart';

import '../../data/chat_location_utils.dart';
import 'chat_location_map.dart';

/// Превью геолокации в сообщении чата.
class ChatLocationPreview extends StatelessWidget {
  const ChatLocationPreview({
    super.key,
    required this.location,
    this.maxWidth = 260,
    this.isMine = false,
  });

  final ChatLocationPoint location;
  final double maxWidth;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor =
        isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final linkColor =
        isMine ? const Color(0xFF8FD3FF) : theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => openChatLocationInYandexMaps(location),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: maxWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ChatLocationMap(
                sendPoint: location,
                height: 150,
                interactive: false,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.location_on_outlined, size: 16, color: textColor),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Геолокация',
                      style: theme.textTheme.labelLarge?.copyWith(color: textColor),
                    ),
                  ),
                  Icon(Icons.open_in_new, size: 16, color: linkColor),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
