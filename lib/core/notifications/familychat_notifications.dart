import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../features/chat/data/incoming_call_coordinator.dart';
import '../push/push_navigation.dart';
import 'notification_inline_reply.dart';

/// Локальные уведомления со звуком (Android/iOS) и каналы Android.
class FamilyChatNotifications {
  FamilyChatNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static const messagesChannelId = 'familychat_messages';
  static const callsChannelId = 'familychat_calls';

  static String chatNotificationTag(int threadId) => 'familychat_chat_$threadId';

  static int chatNotificationId(int threadId) => 100000 + threadId;

  @pragma('vm:entry-point')
  static void _onBackgroundNotificationTap(NotificationResponse response) {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    unawaited(_handleBackgroundNotificationResponse(response));
  }

  static Future<void> _handleBackgroundNotificationResponse(
    NotificationResponse response,
  ) async {
    try {
      await initialize();
      await handleNotificationResponse(response);
    } catch (e, st) {
      debugPrint('background notification action failed: $e\n$st');
    }
  }

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          NotificationInlineReply.iosCategoryId,
          actions: [
            DarwinNotificationAction.text(
              NotificationInlineReply.actionId,
              'Ответить',
              buttonTitle: 'Отправить',
              placeholder: 'Сообщение',
            ),
          ],
          options: {
            DarwinNotificationCategoryOption.hiddenPreviewShowTitle,
          },
        ),
      ],
    );
    final initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
      onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationTap,
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
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
    }

    _initialized = true;
  }

  static void _onNotificationTap(NotificationResponse response) {
    unawaited(handleNotificationResponse(response));
  }

  static Future<void> handleNotificationResponse(
    NotificationResponse response,
  ) async {
    if (response.actionId == NotificationInlineReply.actionId) {
      await _sendInlineReply(response);
      return;
    }
    _handleNotificationPayload(response.payload);
  }

  static Future<void> _sendInlineReply(NotificationResponse response) async {
    final text = response.input?.trim() ?? '';
    if (text.isEmpty) return;
    Map<String, dynamic> data = const {};
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      try {
        data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      } catch (e) {
        debugPrint('inline reply payload error: $e');
        return;
      }
    }
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    // Android держит спиннер RemoteInput, пока то же уведомление не
    // обновят. Нельзя ждать HTTP — сначала снимаем загрузку.
    if (threadId != null) {
      await _stopInlineReplySpinner(
        threadId: threadId,
        text: text,
        data: data,
      );
    }

    final ok = await NotificationInlineReply.sendFromPayload(
      data: data,
      rawText: text,
    );

    if (ok && threadId != null) {
      await clearChatNotifications(threadId: threadId);
      return;
    }
    if (!ok) {
      await showForegroundPush(
        title: 'Family Space',
        body: 'Не удалось отправить ответ. Откройте чат.',
        data: data.isEmpty
            ? <String, dynamic>{'type': 'familychat_chat'}
            : data,
      );
    }
  }

  /// Заменяет баннер с полем ответа — иначе Android крутит вечный прогресс.
  static Future<void> _stopInlineReplySpinner({
    required int threadId,
    required String text,
    required Map<String, dynamic> data,
  }) async {
    await initialize();
    final preview = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    final androidDetails = AndroidNotificationDetails(
      messagesChannelId,
      'Сообщения',
      importance: Importance.low,
      priority: Priority.low,
      playSound: false,
      enableVibration: false,
      silent: true,
      onlyAlertOnce: true,
      autoCancel: true,
      tag: chatNotificationTag(threadId),
      category: AndroidNotificationCategory.message,
    );
    await _plugin.show(
      chatNotificationId(threadId),
      'Family Space',
      preview,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode(data),
    );
  }

  static void _handleNotificationPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    try {
      final data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final type = data['type']?.toString() ?? '';
      if (type == 'familychat_calendar_reminder') {
        openCalendarFromPushData(data);
        return;
      }
      if (type == 'familychat_feed_photos' ||
          data['deeplink']?.toString() == 'feed') {
        openFeedFromPushData(data);
        return;
      }
      if (type == 'familychat_call') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          IncomingCallCoordinator.instance.presentFromPushData(data);
        });
        return;
      }
      openChatFromPushData(data);
    } catch (e) {
      debugPrint('notification tap payload error: $e');
    }
  }

  static Future<void> consumeLaunchNotification() async {
    if (kIsWeb || !_initialized) return;
    await consumePendingNativeReply();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final response = details?.notificationResponse;
    if (response == null) return;
    await handleNotificationResponse(response);
  }

  static Future<void> consumePendingNativeReply() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      const channel = MethodChannel('com.familychat/push_reply');
      final raw = await channel.invokeMethod<dynamic>('takePending');
      if (raw is! Map) return;
      final data = raw.map((key, value) => MapEntry('$key', value));
      final text = data['text']?.toString() ?? '';
      if (text.trim().isEmpty) return;
      await NotificationInlineReply.sendFromPayload(
        data: data,
        rawText: text,
      );
    } catch (e) {
      debugPrint('consumePendingNativeReply: $e');
    }
  }

  static Future<void> handleBackgroundRemoteMessage(RemoteMessage message) async {
    if (kIsWeb) return;
    await initialize();
    final data = Map<String, dynamic>.from(message.data);
    var type = data['type']?.toString() ?? '';
    if (type.isEmpty &&
        data['deeplink']?.toString() == 'chat' &&
        (data['thread_id']?.toString() ?? '').isNotEmpty) {
      type = 'familychat_chat';
      data['type'] = type;
    }

    if (type == 'familychat_chat') {
      final title = data['title']?.toString().trim() ??
          message.notification?.title?.trim();
      final body = data['body']?.toString().trim() ??
          message.notification?.body?.trim();
      await showForegroundPush(
        title: title != null && title.isNotEmpty ? title : 'Family Space',
        body: body != null && body.isNotEmpty ? body : 'Новое сообщение',
        data: data,
      );
      return;
    }

    if (type != 'familychat_call') return;

    final title = data['title']?.toString().trim() ??
        message.notification?.title?.trim();
    final body = data['body']?.toString().trim() ??
        message.notification?.body?.trim();
    await showIncomingCallWakeUp(
      title: title != null && title.isNotEmpty ? title : 'Входящий звонок',
      body: body != null && body.isNotEmpty ? body : 'Family Space',
      data: data,
    );
  }

  static int _notificationId(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    if (type == 'familychat_chat') {
      final threadId = int.tryParse(data['thread_id']?.toString() ?? '') ?? 0;
      return chatNotificationId(threadId);
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

  static String? _androidTag(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    if (type == 'familychat_chat') {
      final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
      if (threadId == null) return 'familychat_chat';
      return chatNotificationTag(threadId);
    }
    return null;
  }

  static Future<void> showIncomingCallWakeUp({
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    if (kIsWeb || !_initialized) return;

    final androidDetails = AndroidNotificationDetails(
      callsChannelId,
      'Звонки',
      channelDescription: 'Входящие звонки',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      playSound: true,
      enableVibration: true,
      visibility: NotificationVisibility.public,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    await _plugin.show(
      _notificationId(data),
      title,
      body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: jsonEncode(data),
    );
  }

  static Future<void> showForegroundPush({
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    if (kIsWeb || !_initialized) return;

    final type = data['type']?.toString() ?? '';
    if (type == 'familychat_call') {
      return;
    }

    final tag = _androidTag(data);
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    final isChat = type == 'familychat_chat' ||
        (data['deeplink']?.toString() == 'chat' && threadId != null);
    final canReply = isChat && threadId != null;
    final androidDetails = AndroidNotificationDetails(
      messagesChannelId,
      'Сообщения',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      playSound: true,
      enableVibration: true,
      tag: tag,
      category: isChat ? AndroidNotificationCategory.message : null,
      actions: canReply
          ? [
              AndroidNotificationAction(
                NotificationInlineReply.actionId,
                'Ответить',
                inputs: const [
                  AndroidNotificationActionInput(
                    label: 'Сообщение',
                    allowFreeFormInput: true,
                  ),
                ],
                allowGeneratedReplies: true,
                showsUserInterface: false,
                // false: Android ждёт notify() с тем же id/tag, иначе спиннер.
                cancelNotification: false,
              ),
            ]
          : null,
      // Один баннер на чат: повторный show с тем же id/tag заменяет старый.
      onlyAlertOnce: false,
    );
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      threadIdentifier: tag ??
          (threadId != null ? chatNotificationTag(threadId) : null),
      categoryIdentifier:
          canReply ? NotificationInlineReply.iosCategoryId : null,
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

  /// Снять пуши сообщений из шторки (весь чат или все сообщения).
  static Future<void> clearChatNotifications({int? threadId}) async {
    if (kIsWeb || !_initialized) return;

    if (threadId != null) {
      final tag = chatNotificationTag(threadId);
      final id = chatNotificationId(threadId);
      // FCM с tag часто публикует с id=0; локальные — с нашим id.
      await _plugin.cancel(0, tag: tag);
      await _plugin.cancel(id, tag: tag);
      await _plugin.cancel(id);
      return;
    }

    try {
      final active = await _plugin.getActiveNotifications();
      for (final n in active) {
        final tag = n.tag;
        final id = n.id;
        final isChatTag = tag != null && tag.startsWith('familychat_chat_');
        final isChatId = id != null && id >= 100000 && id < 200000;
        if (!isChatTag && !isChatId) continue;
        if (id != null) {
          await _plugin.cancel(id, tag: tag);
        } else if (tag != null) {
          await _plugin.cancel(0, tag: tag);
        }
      }
    } catch (e) {
      debugPrint('clearChatNotifications active scan failed: $e');
    }
  }

  /// При открытии приложения — убрать пуши сообщений из шторки.
  static Future<void> clearMessageNotificationsOnAppOpen() async {
    await clearChatNotifications();
  }
}
