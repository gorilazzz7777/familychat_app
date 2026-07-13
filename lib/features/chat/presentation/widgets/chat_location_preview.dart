import 'package:flutter/material.dart';

import '../../data/chat_location_utils.dart';
import 'chat_location_map.dart';

/// Превью геолокации в сообщении чата. Тап по карте — открыть в Яндекс.Картах.
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => openChatLocationInYandexMaps(location),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: maxWidth,
          child: ChatLocationMap(
            sendPoint: location,
            height: 150,
            interactive: false,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
