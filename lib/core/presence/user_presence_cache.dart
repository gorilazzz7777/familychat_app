import 'package:flutter/foundation.dart';

import '../../features/chat/data/chat_realtime_utils.dart';

/// Latest presence snapshots received over WebSocket.
class UserPresenceCache extends ChangeNotifier {
  UserPresenceCache._();

  static final UserPresenceCache instance = UserPresenceCache._();

  final Map<int, Map<String, dynamic>> _byUserId = {};

  Map<String, dynamic>? snapshot(int userId) => _byUserId[userId];

  void applyEvent(Map<String, dynamic> event) {
    final userId = chatAsInt(event['user_id']);
    if (userId == null) return;
    _byUserId[userId] = Map<String, dynamic>.from(event);
    notifyListeners();
  }
}

Map<String, dynamic> profileFromPresenceEvent(Map<String, dynamic> event) {
  return {
    'is_online': event['is_online'] == true,
    'last_seen': event['last_seen']?.toString(),
  };
}
