import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../push/push_navigation.dart';

/// Локальные уведомления со звуком (Android/iOS) и каналы Android.
class FamilyChatNotifications {
  FamilyChatNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static const messagesChannelId = 'familychat_messages';
  static const callsChannelId = 'familychat_calls';

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: DarwinInitializationSettings(),
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          messagesChannelId,
          'Сообщения',
          description: 'Новые сообщения в чатах',
          importance: Importance.defaultImportance,
          playSound: true,
          enableVibration: true,
        ),
      );
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          callsChannelId,
          'Звонки',
          description: 'Входящие звонки',
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );
    }

    _initialized = true;
  }

  static void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final type = data['type']?.toString() ?? '';
      if (type == 'familychat_chat') {
        openChatFromPushData(data);
      } else if (type == 'familychat_calendar_reminder') {
        openCalendarFromPushData(data);
      } else if (type == 'familychat_call') {
        openCallFromPushData(data);
      }
    } catch (e) {
      debugPrint('notification tap payload error: $e');
    }
  }

  static int _notificationId(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    if (type == 'familychat_chat') {
      final threadId = int.tryParse(data['thread_id']?.toString() ?? '') ?? 0;
      return 100000 + threadId;
    }
    if (type == 'familychat_calendar_reminder') {
      final eventId = int.tryParse(data['event_id']?.toString() ?? '') ?? 0;
      return 200000 + eventId;
    }
    if (type == 'familychat_call') {
      final callId = int.tryParse(data['session_id']?.toString() ?? '') ?? 0;
      return 300000 + callId;
    }
    return DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  }

  static Future<void> showForegroundPush({
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    if (kIsWeb || !_initialized) return;

    final type = data['type']?.toString() ?? '';
    final channelId = type == 'familychat_call'
        ? callsChannelId
        : messagesChannelId;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      type == 'familychat_call' ? 'Звонки' : 'Сообщения',
      importance: type == 'familychat_call'
          ? Importance.high
          : Importance.defaultImportance,
      priority: type == 'familychat_call'
          ? Priority.high
          : Priority.defaultPriority,
      playSound: true,
      enableVibration: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _plugin.show(
      _notificationId(data),
      title,
      body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: jsonEncode(data),
    );
  }

  static Future<void> cancelCallNotification(int callId) async {
    if (kIsWeb || !_initialized) return;
    await _plugin.cancel(300000 + callId);
  }
}
