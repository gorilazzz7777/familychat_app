import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';

/// Detect Telegram MTProto / TDLib FCM payloads (not FamilyChat server pushes).
bool isTelegramFcmData(Map<String, dynamic> data) {
  final type = data['type']?.toString() ?? '';
  if (type.startsWith('familychat')) return false;
  final deeplink = data['deeplink']?.toString() ?? '';
  if (deeplink == 'chat' || deeplink == 'feed' || deeplink == 'calendar') {
    return false;
  }
  if ((data['thread_id']?.toString() ?? '').isNotEmpty) return false;
  if (data.containsKey('p')) return true;
  if ((data['loc_key']?.toString() ?? '').isNotEmpty) return true;
  if (data['custom'] is Map) return true;
  return false;
}

bool isTelegramRemoteMessage(RemoteMessage message) {
  return isTelegramFcmData(Map<String, dynamic>.from(message.data));
}

/// JSON payload for TDLib [processPushNotification].
String buildTdlibProcessPushPayload(RemoteMessage message) {
  final map = <String, dynamic>{
    ...message.data.map((k, v) => MapEntry(k, v)),
  };
  final sent = message.sentTime?.millisecondsSinceEpoch;
  if (sent != null) {
    map.putIfAbsent('google.sent_time', () => sent);
  }
  final sound = message.notification?.android?.sound;
  if (sound != null && sound.isNotEmpty) {
    map.putIfAbsent('google.notification.sound', () => sound);
  }
  return jsonEncode(map);
}

const kTdlibPushType = 'tdlib_tg_chat';

int tdlibChatNotificationId(int chatId) =>
    500000 + (chatId.abs() % 400000);

String tdlibChatNotificationTag(int chatId) => 'tdlib_tg_$chatId';
