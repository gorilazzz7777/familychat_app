import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

const birthdayChatAvatarAsset = 'assets/chat/birthday_celebration_avatar.jpg';
const familyChatAvatarAsset = 'assets/chat/family_chat_avatar.jpg';

/// Локальная картинка аватара чата (семья / день рождения).
String? chatThreadAvatarAsset({
  required String kind,
  bool isBirthdayCelebration = false,
}) {
  if (isBirthdayCelebration) return birthdayChatAvatarAsset;
  if (kind == 'family') return familyChatAvatarAsset;
  return null;
}

bool chatThreadHasAssetAvatar({
  required String kind,
  bool isBirthdayCelebration = false,
}) {
  return chatThreadAvatarAsset(
        kind: kind,
        isBirthdayCelebration: isBirthdayCelebration,
      ) !=
      null;
}

bool isSavedMessagesThread(String? kind) => kind == 'saved';

/// Аватар чата «Избранное».
class SavedMessagesAvatar extends StatelessWidget {
  const SavedMessagesAvatar({super.key, this.radius = 24});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      child: Icon(
        LucideIcons.bookmark,
        size: radius * 0.95,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}
