import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/chat/data/incoming_call_coordinator.dart';
import '../push/push_navigation.dart';
import 'chat_push_notification_style.dart';
import 'chat_push_thread_preview.dart';
import 'notification_inline_reply.dart';
import 'push_reply_trace.dart';

/// Локальные уведомления со звуком (Android/iOS) и каналы Android.
class FamilyChatNotifications {
  FamilyChatNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static const _pushDedupeWindowMs = 30000;
  static const _handledInlineReplyPrefix = 'inline_reply_handled_';
  static final Set<String> _inlineReplyInFlight = {};

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

  @pragma('vm:entry-point')
  static Future<void> _handleBackgroundNotificationResponse(
    NotificationResponse response,
  ) async {
    PushReplyTrace.log(
      'action_received',
      source: 'background',
      extra: {
        'actionId': response.actionId ?? '',
        'inputLen': response.input?.length ?? 0,
        'payloadLen': response.payload?.length ?? 0,
        'notificationId': response.id ?? -1,
      },
    );
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      await initialize();
      await handleNotificationResponse(response);
    } catch (e, st) {
      PushReplyTrace.log(
        'background_handler_fail',
        source: 'background',
        detail: '$e',
      );
      debugPrint('background notification action failed: $e\n$st');
      if (response.actionId == NotificationInlineReply.actionId) {
        final data = _parseNotificationPayload(response.payload);
        final threadId = _threadIdFromNotificationResponse(data, response);
        if (threadId != null) {
          await _dismissChatNotificationForInlineReply(
            threadId: threadId,
            outgoingText: response.input ?? '',
          );
        }
      }
    }
  }

  @pragma('vm:entry-point')
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
          importance: Importance.high,
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

  @pragma('vm:entry-point')
  static Future<void> handleNotificationResponse(
    NotificationResponse response,
  ) async {
    if (response.actionId == NotificationInlineReply.actionId) {
      final fingerprint = _inlineReplyFingerprint(response);
      if (!await _tryClaimInlineReply(fingerprint)) {
        PushReplyTrace.log(
          'dedupe_handled',
          source: 'foreground',
          extra: {'fingerprint': fingerprint},
        );
        await clearAndroidLaunchNotificationIntent();
        return;
      }
      PushReplyTrace.log(
        'action_received',
        source: 'foreground',
        extra: {
          'actionId': response.actionId ?? '',
          'inputLen': response.input?.length ?? 0,
          'payloadLen': response.payload?.length ?? 0,
          'notificationId': response.id ?? -1,
        },
      );
      try {
        await _sendInlineReply(response);
      } finally {
        _inlineReplyInFlight.remove(fingerprint);
        await clearAndroidLaunchNotificationIntent();
      }
      return;
    }
    _handleNotificationPayload(response.payload);
  }

  static String _inlineReplyFingerprint(NotificationResponse response) {
    final input = response.input?.trim() ?? '';
    return '${response.id ?? 0}|${response.actionId ?? ''}|$input';
  }

  static Future<bool> _tryClaimInlineReply(String fingerprint) async {
    if (fingerprint.isEmpty) return false;
    if (_inlineReplyInFlight.contains(fingerprint)) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('$_handledInlineReplyPrefix$fingerprint') == true) {
        return false;
      }
      await prefs.setBool('$_handledInlineReplyPrefix$fingerprint', true);
    } catch (_) {
      return false;
    }
    _inlineReplyInFlight.add(fingerprint);
    return true;
  }

  static Future<void> clearAndroidLaunchNotificationIntent() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      const channel = MethodChannel('com.familychat/push_reply');
      await channel.invokeMethod<void>('clearLaunchNotificationIntent');
    } catch (e) {
      debugPrint('clearAndroidLaunchNotificationIntent: $e');
    }
  }

  static Map<String, dynamic> _parseNotificationPayload(String? payload) {
    if (payload == null || payload.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(payload) as Map);
    } catch (e) {
      debugPrint('inline reply payload error: $e');
      return {};
    }
  }

  static int? _threadIdFromNotificationResponse(
    Map<String, dynamic> data,
    NotificationResponse response,
  ) {
    final fromPayload = int.tryParse(data['thread_id']?.toString() ?? '');
    if (fromPayload != null) return fromPayload;
    final id = response.id;
    if (id == null || id < 100000 || id >= 200000) return null;
    return id - 100000;
  }

  static Map<String, dynamic> _ensureChatPayload(
    Map<String, dynamic> data,
    int threadId,
  ) {
    final out = Map<String, dynamic>.from(data);
    out['type'] ??= 'familychat_chat';
    out['deeplink'] ??= 'chat';
    out['thread_id'] ??= '$threadId';
    return out;
  }

  static Future<void> _sendInlineReply(NotificationResponse response) async {
    final text = response.input?.trim() ?? '';
    if (text.isEmpty) {
      PushReplyTrace.log('skip_empty_input', source: 'ui');
      return;
    }

    var data = _parseNotificationPayload(response.payload);
    final threadId = _threadIdFromNotificationResponse(data, response);
    if (threadId == null) {
      PushReplyTrace.log(
        'skip_no_thread',
        source: 'ui',
        detail: 'payload=${response.payload}',
      );
      debugPrint('inline reply: missing thread_id (payload=${response.payload})');
      return;
    }
    data = _ensureChatPayload(data, threadId);

    PushReplyTrace.log(
      'dismiss_start',
      threadId: threadId,
      source: 'ui',
      extra: {'bodyLen': text.length},
    );
    await _dismissChatNotificationForInlineReply(
      threadId: threadId,
      outgoingText: text,
    );
    PushReplyTrace.log('dismiss_done', threadId: threadId, source: 'ui');

    var ok = false;
    try {
      ok = await NotificationInlineReply.sendFromPayload(
        data: data,
        rawText: text,
        source: 'ui',
      );
    } catch (e, st) {
      PushReplyTrace.log(
        'send_exception',
        threadId: threadId,
        source: 'ui',
        detail: '$e',
      );
      debugPrint('inline reply send failed: $e\n$st');
      ok = false;
    }

    if (ok) {
      PushReplyTrace.log('done_ok', threadId: threadId, source: 'ui');
      return;
    }

    PushReplyTrace.log('done_fail_show_banner', threadId: threadId, source: 'ui');
    await showForegroundPush(
      title: 'Family Space',
      body: 'Не удалось отправить ответ. Откройте чат.',
      data: data,
    );
  }

  /// Мгновенно убирает баннер и RemoteInput-спиннер.
  static Future<void> _dismissChatNotificationForInlineReply({
    required int threadId,
    required String outgoingText,
  }) async {
    await initialize();
    final tag = chatNotificationTag(threadId);
    final id = chatNotificationId(threadId);
    await _plugin.cancel(0, tag: tag);
    await _plugin.cancel(id, tag: tag);
    await _plugin.cancel(id);
    await ChatPushThreadPreview.recordOutgoing(threadId, outgoingText);
  }

  static MessagingStyleInformation? _androidMessagingStyle(
    ChatPushThreadPreview preview,
  ) =>
      ChatPushNotificationStyle.androidMessagingStyle(preview);

  static List<AndroidNotificationAction> _chatReplyActions() {
    return [
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
        // true → PendingIntent в MainActivity (основной Flutter engine).
        // false → ActionBroadcastReceiver; ломается с «Engine is already initialised»
        // после FCM background handler в том же процессе.
        showsUserInterface: true,
        cancelNotification: true,
      ),
    ];
  }

  static Future<({
    String title,
    String body,
    MessagingStyleInformation? messagingStyle,
    String? androidSubText,
  })> _resolveChatNotificationContent({
    required int threadId,
    required Map<String, dynamic> data,
    required String pushTitle,
    required String pushBody,
    bool enrichFromDatabase = false,
  }) async {
    final preview = await ChatPushThreadPreview.build(
      threadId: threadId,
      data: data,
      pushTitle: pushTitle,
      pushBody: pushBody,
      enrichFromDatabase: enrichFromDatabase,
    );
    var displayTitle = preview.title;
    var displayBody = ChatPushNotificationStyle.collapsedBody(preview);
    String? androidSubText;
    MessagingStyleInformation? messagingStyle;
    if (defaultTargetPlatform == TargetPlatform.android &&
        preview.lines.isNotEmpty) {
      messagingStyle = _androidMessagingStyle(preview);
      androidSubText = ChatPushNotificationStyle.androidSubText(preview);
    } else if (defaultTargetPlatform == TargetPlatform.iOS &&
        preview.lines.length > 1) {
      displayBody = ChatPushNotificationStyle.expandedBody(preview);
    }
    return (
      title: displayTitle,
      body: displayBody,
      messagingStyle: messagingStyle,
      androidSubText: androidSubText,
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
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await consumePendingNativeReply();
    }
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final response = details?.notificationResponse;
    if (response == null) return;
    await handleNotificationResponse(response);
    await clearAndroidLaunchNotificationIntent();
  }

  static Future<void> consumePendingNativeReply() async {
    if (kIsWeb) return;
    // Android inline reply идёт через onDidReceiveNotificationResponse (showsUserInterface).
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      const channel = MethodChannel('com.familychat/push_reply');
      final raw = await channel.invokeMethod<dynamic>('takePending');
      if (raw is! Map) return;
      final data = raw.map((key, value) => MapEntry('$key', value));
      final text = data['text']?.toString() ?? '';
      if (text.trim().isEmpty) return;

      final payloadJson = data.remove('payload')?.toString();
      if (payloadJson != null && payloadJson.isNotEmpty) {
        try {
          final payload = Map<String, dynamic>.from(
            jsonDecode(payloadJson) as Map,
          );
          data.addAll(payload.map((key, value) => MapEntry('$key', value)));
        } catch (e) {
          debugPrint('consumePendingNativeReply payload parse: $e');
        }
      }

      PushReplyTrace.log(
        'native_pending',
        source: 'ios_pending',
        extra: {
          'threadId': data['thread_id']?.toString() ?? '',
          'bodyLen': text.length,
        },
      );
      await NotificationInlineReply.sendFromPayload(
        data: data,
        rawText: text,
        source: 'ios_pending',
      );
    } catch (e) {
      debugPrint('consumePendingNativeReply: $e');
    }
  }

  @pragma('vm:entry-point')
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
        enrichChatPreviewFromDatabase: true,
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

  static Future<bool> _markChatPushShown(Map<String, dynamic> data) async {
    final messageId = int.tryParse(data['message_id']?.toString() ?? '');
    if (messageId == null || messageId <= 0) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'familychat_push_dedupe_$messageId';
      final seenAt = prefs.getInt(key);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (seenAt != null && now - seenAt < _pushDedupeWindowMs) {
        debugPrint(
          '[FamilyChatNotifications] skip duplicate push message_id=$messageId',
        );
        return false;
      }
      await prefs.setInt(key, now);
      return true;
    } catch (e) {
      debugPrint('[FamilyChatNotifications] dedupe check failed: $e');
      return true;
    }
  }

  @pragma('vm:entry-point')
  static Future<void> showForegroundPush({
    required String title,
    required String body,
    required Map<String, dynamic> data,
    bool enrichChatPreviewFromDatabase = false,
  }) async {
    if (kIsWeb) return;
    await initialize();
    if (!_initialized) return;

    final type = data['type']?.toString() ?? '';
    if (type == 'familychat_call') {
      return;
    }

    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    final isChat = type == 'familychat_chat' ||
        (data['deeplink']?.toString() == 'chat' && threadId != null);
    if (isChat && !await _markChatPushShown(data)) {
      return;
    }

    try {
      await _showForegroundPushImpl(
        title: title,
        body: body,
        data: data,
        enrichChatPreviewFromDatabase: enrichChatPreviewFromDatabase,
      );
    } catch (e, st) {
      debugPrint('showForegroundPush failed: $e\n$st');
      await _showSimpleFallbackPush(
        title: title,
        body: body,
        data: data,
      );
    }
  }

  static Future<void> _showForegroundPushImpl({
    required String title,
    required String body,
    required Map<String, dynamic> data,
    required bool enrichChatPreviewFromDatabase,
  }) async {
    final type = data['type']?.toString() ?? '';
    final tag = _androidTag(data);
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    final isChat = type == 'familychat_chat' ||
        (data['deeplink']?.toString() == 'chat' && threadId != null);
    final canReply = isChat && threadId != null;

    var displayTitle = title;
    var displayBody = body;
    MessagingStyleInformation? messagingStyle;
    String? androidSubText;
    if (isChat && threadId != null) {
      final content = await _resolveChatNotificationContent(
        threadId: threadId,
        data: data,
        pushTitle: title,
        pushBody: body,
        enrichFromDatabase: enrichChatPreviewFromDatabase,
      );
      displayTitle = content.title;
      displayBody = content.body;
      messagingStyle = content.messagingStyle;
      androidSubText = content.androidSubText;
    }

    final androidDetails = AndroidNotificationDetails(
      messagesChannelId,
      'Сообщения',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      tag: tag,
      subText: androidSubText,
      color: isChat ? ChatPushNotificationStyle.notificationColor : null,
      colorized: isChat,
      category: isChat ? AndroidNotificationCategory.message : null,
      styleInformation: messagingStyle,
      actions: canReply ? _chatReplyActions() : null,
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
      displayTitle,
      displayBody,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: jsonEncode(data),
    );
  }

  static Future<void> _showSimpleFallbackPush({
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    final type = data['type']?.toString() ?? '';
    final threadId = int.tryParse(data['thread_id']?.toString() ?? '');
    final isChat = type == 'familychat_chat' ||
        (data['deeplink']?.toString() == 'chat' && threadId != null);
    final tag = _androidTag(data);
    final androidDetails = AndroidNotificationDetails(
      messagesChannelId,
      'Сообщения',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      tag: tag,
      category: isChat ? AndroidNotificationCategory.message : null,
      actions: isChat && threadId != null ? _chatReplyActions() : null,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    await _plugin.show(
      _notificationId(data),
      title.isNotEmpty ? title : 'Family Space',
      body.isNotEmpty ? body : 'Новое сообщение',
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
      await ChatPushThreadPreview.clear(threadId);
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
