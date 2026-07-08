enum UserPresenceKind {
  online,
  justNow,
  recently,
  longAgo,
}

class UserPresence {
  const UserPresence({required this.kind, required this.label});

  final UserPresenceKind kind;
  final String label;
}

UserPresence resolveUserPresence({
  bool isOnline = false,
  DateTime? lastSeen,
}) {
  if (isOnline) {
    return const UserPresence(
      kind: UserPresenceKind.online,
      label: 'Онлайн',
    );
  }
  if (lastSeen == null) {
    return const UserPresence(
      kind: UserPresenceKind.longAgo,
      label: 'Был давно',
    );
  }
  final diff = DateTime.now().toUtc().difference(lastSeen.toUtc());
  if (diff <= const Duration(hours: 1)) {
    return const UserPresence(
      kind: UserPresenceKind.justNow,
      label: 'Был только что',
    );
  }
  if (diff <= const Duration(days: 4)) {
    return const UserPresence(
      kind: UserPresenceKind.recently,
      label: 'Был недавно',
    );
  }
  return const UserPresence(
    kind: UserPresenceKind.longAgo,
    label: 'Был давно',
  );
}

UserPresence userPresenceFromProfile(Map<String, dynamic> profile) {
  final isOnline = profile['is_online'] == true;
  final lastSeenStr = profile['last_seen']?.toString();
  DateTime? lastSeen;
  if (lastSeenStr != null && lastSeenStr.isNotEmpty) {
    lastSeen = DateTime.tryParse(lastSeenStr);
  }
  return resolveUserPresence(isOnline: isOnline, lastSeen: lastSeen);
}
