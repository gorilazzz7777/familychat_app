/// Shared call helpers (TeamCoach-safe; video flags are optional).
bool parseCallIsVideo(Object? raw) {
  if (raw == true) return true;
  if (raw == false || raw == null) return false;
  final s = raw.toString().trim().toLowerCase();
  return s == '1' || s == 'true' || s == 'yes';
}

/// Whether this peer should apply an SDP/ICE signal from [fromUserId].
bool shouldAcceptCallSignal(
  String type, {
  required bool isCaller,
  int? myUserId,
  int? fromUserId,
  bool allowRenegotiation = false,
}) {
  if (fromUserId != null && myUserId != null && fromUserId == myUserId) {
    return false;
  }
  if (type == 'ice') return true;
  if (allowRenegotiation) {
    return type == 'offer' || type == 'answer';
  }
  if (isCaller) return type == 'answer';
  return type == 'offer';
}
