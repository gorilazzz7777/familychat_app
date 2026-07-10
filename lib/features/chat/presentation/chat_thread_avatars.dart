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
