import 'package:intl/intl.dart';

import '../i18n/gender_verbs.dart';

enum UserPresenceKind {
  online,
  justNow,
  recently,
  longAgo,
  exact,
}

class UserPresence {
  const UserPresence({required this.kind, required this.label});

  final UserPresenceKind kind;
  final String label;
}

String presenceWasForm(String gender) {
  return genderVerb(gender, male: 'Был', female: 'Была');
}

String formatPreciseLastSeen(DateTime lastSeen, {required String gender}) {
  final was = presenceWasForm(gender);
  final local = lastSeen.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final time = DateFormat('HH:mm', 'ru').format(local);

  if (day == today) {
    return '$was сегодня в $time';
  }
  final yesterday = today.subtract(const Duration(days: 1));
  if (day == yesterday) {
    return '$was вчера в $time';
  }
  if (local.year == now.year) {
    final date = DateFormat('d MMM', 'ru').format(local);
    return '$was $date в $time';
  }
  final date = DateFormat('d MMM yyyy', 'ru').format(local);
  return '$was $date в $time';
}

UserPresence resolveUserPresence({
  bool isOnline = false,
  DateTime? lastSeen,
  String gender = 'male',
  bool preciseLastSeen = false,
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

  if (preciseLastSeen) {
    return UserPresence(
      kind: UserPresenceKind.exact,
      label: formatPreciseLastSeen(lastSeen, gender: gender),
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

UserPresence userPresenceFromProfile(
  Map<String, dynamic> profile, {
  bool preciseLastSeen = false,
}) {
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
    preciseLastSeen: preciseLastSeen,
  );
}