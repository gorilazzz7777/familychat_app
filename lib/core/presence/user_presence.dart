import '../i18n/gender_verbs.dart';

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

String presenceWasForm(String gender) {
  return genderVerb(gender, male: 'Был', female: 'Была');
}

UserPresence resolveUserPresence({
  bool isOnline = false,
  DateTime? lastSeen,
  String gender = 'male',
}) {
  if (isOnline) {
    return const UserPresence(
      kind: UserPresenceKind.online,
      label: 'Онлайн',
    );
  }

  final was = presenceWasForm(gender);
  if (lastSeen == null) {
    return UserPresence(
      kind: UserPresenceKind.longAgo,
      label: '$was давно',
    );
  }
  final diff = DateTime.now().toUtc().difference(lastSeen.toUtc());
  if (diff <= const Duration(hours: 1)) {
    return UserPresence(
      kind: UserPresenceKind.justNow,
      label: '$was только что',
    );
  }
  if (diff <= const Duration(days: 4)) {
    return UserPresence(
      kind: UserPresenceKind.recently,
      label: '$was недавно',
    );
  }
  return UserPresence(
    kind: UserPresenceKind.longAgo,
    label: '$was давно',
  );
}

UserPresence userPresenceFromProfile(Map<String, dynamic> profile) {
  final isOnline = profile['is_online'] == true;
  final gender = profile['gender']?.toString() ?? 'male';
  final lastSeenStr = profile['last_seen']?.toString();
  DateTime? lastSeen;
  if (lastSeenStr != null && lastSeenStr.isNotEmpty) {
    lastSeen = DateTime.tryParse(lastSeenStr);
  }
  return resolveUserPresence(
    isOnline: isOnline,
    lastSeen: lastSeen,
    gender: gender,
  );
}
