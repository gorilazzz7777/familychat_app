final _familychatProfileAvatarPath =
    RegExp(r'familychat/profiles/(\d+)/', caseSensitive: false);

/// user_id из публичного URL аватара в Object Storage.
int? userIdFromFamilychatProfileAvatarUrl(String url) {
  final match = _familychatProfileAvatarPath.firstMatch(url.trim());
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

bool isFamilychatProfileAvatarStorageUrl(String url) {
  return userIdFromFamilychatProfileAvatarUrl(url) != null;
}
