import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the process elevated while media uploads run (chat / feed / album).
///
/// Android: `dataSync` foreground service + ongoing notification.
/// iOS: best-effort background task (OS may still suspend after a short window).
///
/// Use [enter]/[leave] with a stable [scope] so concurrent uploaders
/// (chat outbox + album + feed) share one FGS and only stop when all finish.
abstract final class MediaUploadForeground {
  static const channelId = 'familychat_uploads';
  static const serviceId = 42001;

  static const scopeChat = 'chat';
  static const scopeFeed = 'feed';
  static const scopeAlbum = 'album';

  static bool _initialized = false;
  static final Set<String> _scopes = {};

  static void initCommunicationPort() {
    if (kIsWeb) return;
    FlutterForegroundTask.initCommunicationPort();
  }

  static void ensureInitialized() {
    if (kIsWeb || _initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: channelId,
        channelName: 'Отправка медиа',
        channelDescription:
            'Показывается, пока медиа (чат, лента, альбомы) отправляются в фоне',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        // dataSync must not auto-start from BOOT_COMPLETED on Android 15+.
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: false,
        stopWithTask: true,
      ),
    );
  }

  /// Raise process priority for [scope] (idempotent per scope).
  static Future<void> enter(String scope) async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    ensureInitialized();
    final wasEmpty = _scopes.isEmpty;
    _scopes.add(scope);
    if (!wasEmpty) return;
    await _startService();
  }

  /// Drop [scope]; stop FGS when no scopes remain.
  static Future<void> leave(String scope) async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (!_scopes.remove(scope)) return;
    if (_scopes.isNotEmpty) return;
    await _stopService();
  }

  static Future<void> _startService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      final result = await FlutterForegroundTask.startService(
        serviceId: serviceId,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Отправка медиа',
        notificationText: 'Файлы ещё отправляются…',
        callback: mediaUploadForegroundStartCallback,
      );
      if (result is ServiceRequestFailure) {
        debugPrint(
          '[MediaUploadForeground] start failed: ${result.error}',
        );
        _scopes.clear();
      }
    } catch (e, st) {
      debugPrint('[MediaUploadForeground] start error: $e\n$st');
      _scopes.clear();
    }
  }

  static Future<void> _stopService() async {
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        debugPrint(
          '[MediaUploadForeground] stop failed: ${result.error}',
        );
      }
    } catch (e, st) {
      debugPrint('[MediaUploadForeground] stop error: $e\n$st');
    }
  }
}

@pragma('vm:entry-point')
void mediaUploadForegroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_MediaUploadTaskHandler());
}

/// Minimal handler: FGS keeps the process alive; uploads stay on the UI isolate.
class _MediaUploadTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
