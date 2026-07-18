import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network/api_client.dart';
import '../notifications/familychat_notifications.dart';
import '../platform/browser_info.dart';
import '../../features/familychat/data/familychat_repository.dart';
import '../../firebase_options.dart';
import 'web_fcm_service_worker.dart';
import 'web_fcm_token.dart';
import 'web_push_bridge.dart';
import 'push_message_handler.dart';

@pragma('vm:entry-point')
Future<void> familychatFirebaseBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await PushRegistrationService.ensureFirebaseInitialized();
  await FamilyChatNotifications.handleBackgroundRemoteMessage(message);
}

enum WebPushRegistrationResult {
  success,
  permissionDenied,
  notConfigured,
  tokenFailed,
  serverFailed,
  failed,
}

enum PushPermissionStatus {
  granted,
  denied,
  notDetermined,
  unsupported,
}

class PushRegistrationService {
  PushRegistrationService._();

  static bool _wired = false;
  static String? lastWebPushError;
  static Future<void>? _firebaseInitFuture;
  static Future<WebPushRegistrationResult>? _registerWebPushFuture;
  static StreamSubscription<RemoteMessage>? _onMessageSub;
  static StreamSubscription<RemoteMessage>? _onMessageOpenedSub;
  static StreamSubscription<String>? _onTokenRefreshSub;
  static Future<void>? _wireLock;

  static void _failStep(String step, Object error, [StackTrace? st]) {
    lastWebPushError = '$step: $error';
    debugPrint('[FCM] $step: $error${st == null ? '' : '\n$st'}');
  }

  static Future<void> ensureFirebaseInitialized() async {
    if (kIsWeb) return;

    if (Firebase.apps.isNotEmpty) return;

    if (_firebaseInitFuture != null) {
      await _firebaseInitFuture;
      return;
    }

    _firebaseInitFuture = _initDefaultFirebaseOnce();
    try {
      await _firebaseInitFuture;
    } catch (e, st) {
      _failStep('firebaseInit', e, st);
      _firebaseInitFuture = null;
    }
  }

  static Future<void> _initDefaultFirebaseOnce() async {
    final options = DefaultFirebaseOptions.currentPlatform;
    if (options == null) {
      await Firebase.initializeApp();
      return;
    }

    if (Firebase.apps.isNotEmpty) return;

    try {
      await Firebase.initializeApp(options: options);
    } on FirebaseException catch (e) {
      if (e.code == 'duplicate-app' && Firebase.apps.isNotEmpty) return;
      if (Firebase.apps.isNotEmpty) return;
      rethrow;
    } catch (e) {
      if (Firebase.apps.isNotEmpty) return;
      rethrow;
    }
  }

  static Future<bool> registerIfPossible({
    required ApiClient client,
    required FamilyChatRepository repository,
  }) async {
    final status = await getPushPermissionStatus();
    if (status != PushPermissionStatus.granted) return false;
    try {
      return await _registerGranted(repository);
    } catch (e, st) {
      _failStep('registerIfPossible', e, st);
      return false;
    }
  }

  /// Сброс состояния при выходе (повторная регистрация после нового входа).
  static void resetSession() {
    _wired = false;
    lastWebPushError = null;
    _wireLock = null;
    unawaited(_onMessageSub?.cancel());
    unawaited(_onMessageOpenedSub?.cancel());
    unawaited(_onTokenRefreshSub?.cancel());
    _onMessageSub = null;
    _onMessageOpenedSub = null;
    _onTokenRefreshSub = null;
  }

  static Future<bool> isPushSupported() async {
    if (kIsWeb) {
      if (!webNotificationsSupported) return false;
      if (isIosBrowser && !isStandalonePwa) return false;
      return true;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static bool get _isNativeMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static String get _nativePlatformName =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  static Future<PushPermissionStatus> getPushPermissionStatus() async {
    if (!await isPushSupported()) return PushPermissionStatus.unsupported;

    if (kIsWeb) {
      return switch (webNotificationPermission) {
        'granted' => PushPermissionStatus.granted,
        'denied' => PushPermissionStatus.denied,
        _ => PushPermissionStatus.notDetermined,
      };
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await ensureFirebaseInitialized();
      if (Firebase.apps.isEmpty) return PushPermissionStatus.unsupported;
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      return switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional =>
          PushPermissionStatus.granted,
        AuthorizationStatus.denied => PushPermissionStatus.denied,
        AuthorizationStatus.notDetermined => PushPermissionStatus.notDetermined,
      };
    }

    final permission = await Permission.notification.status;
    if (permission.isGranted) return PushPermissionStatus.granted;
    if (permission.isPermanentlyDenied) return PushPermissionStatus.denied;
    return PushPermissionStatus.notDetermined;
  }

  static Future<bool> isNativePermissionPermanentlyDenied() async {
    if (!_isNativeMobile) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await ensureFirebaseInitialized();
      if (Firebase.apps.isEmpty) return false;
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.denied;
    }
    return Permission.notification.isPermanentlyDenied;
  }

  static Future<void> openNotificationSettings() async {
    await openAppSettings();
  }

  static Future<WebPushRegistrationResult> requestPushAfterLogin(
    FamilyChatRepository repository,
  ) async {
    if (!await isPushSupported()) {
      return WebPushRegistrationResult.failed;
    }

    if (kIsWeb) {
      return registerWebPush(repository);
    }

    if (_isNativeMobile) {
      final ok = await _registerNative(repository, requestPermission: true);
      if (!ok) {
        final status = await getPushPermissionStatus();
        if (status == PushPermissionStatus.denied ||
            status == PushPermissionStatus.notDetermined) {
          return WebPushRegistrationResult.permissionDenied;
        }
        return WebPushRegistrationResult.serverFailed;
      }
      return WebPushRegistrationResult.success;
    }

    return WebPushRegistrationResult.failed;
  }

  static Future<bool> _registerGranted(FamilyChatRepository repository) async {
    if (kIsWeb) {
      final result = await registerWebPush(repository);
      if (result == WebPushRegistrationResult.success) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('familychat_web_push_registered', true);
        return true;
      }
      return false;
    }
    if (_isNativeMobile) {
      return _registerNative(repository, requestPermission: false);
    }
    return false;
  }

  static Future<WebPushRegistrationResult> registerWebPush(
    FamilyChatRepository repository,
  ) async {
    if (!kIsWeb) return WebPushRegistrationResult.failed;

    if (_registerWebPushFuture != null) {
      return _registerWebPushFuture!;
    }

    lastWebPushError = null;
    _registerWebPushFuture = _registerWebPushOnce(repository);
    try {
      return await _registerWebPushFuture!;
    } finally {
      _registerWebPushFuture = null;
    }
  }

  static Future<WebPushRegistrationResult> _registerWebPushOnce(
    FamilyChatRepository repository,
  ) async {
    try {
      return await _registerWeb(repository);
    } catch (e, st) {
      _failStep('registerWebPush', e, st);
      return WebPushRegistrationResult.failed;
    }
  }

  static Future<bool> _registerNative(
    FamilyChatRepository repository, {
    bool requestPermission = true,
  }) async {
    await ensureFirebaseInitialized();
    if (Firebase.apps.isEmpty) return false;

    final messaging = FirebaseMessaging.instance;
    final platform = _nativePlatformName;

    if (requestPermission) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final settings = await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
        final granted =
            settings.authorizationStatus == AuthorizationStatus.authorized ||
                settings.authorizationStatus == AuthorizationStatus.provisional;
        if (!granted) return false;
      } else {
        final permission = await Permission.notification.status;
        if (!permission.isGranted && !permission.isPermanentlyDenied) {
          await Permission.notification.request();
        }
        if (!await Permission.notification.isGranted) return false;
      }
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      if (!await Permission.notification.isGranted) return false;
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final settings = await messaging.getNotificationSettings();
      final granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!granted) return false;
    }

    await FamilyChatNotifications.initialize();

    try {
      // APNs token нужен до getToken() на iOS.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
        final apns = await messaging.getAPNSToken();
        if (apns == null) {
          // Короткое ожидание после registerForRemoteNotifications.
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }

      final token = await messaging.getToken();
      if (token == null || token.isEmpty) return false;
      await repository.registerFcm(token: token, platform: platform);
      await _wireHandlers(messaging, repository, platform: platform);
      return true;
    } catch (e, st) {
      _failStep('registerFcm', e, st);
      _wired = false;
      return false;
    }
  }

  static Future<WebPushRegistrationResult> _registerWeb(
    FamilyChatRepository repository,
  ) async {
    try {
      await ensureFcmServiceWorkerRegistered();
    } catch (e, st) {
      _failStep('serviceWorker', e, st);
      return WebPushRegistrationResult.tokenFailed;
    }

    const vapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY');
    if (vapidKey.isEmpty) {
      lastWebPushError = 'config: FIREBASE_VAPID_KEY пуст';
      return WebPushRegistrationResult.notConfigured;
    }

    const apiKey = String.fromEnvironment('FIREBASE_WEB_API_KEY');
    if (apiKey.isEmpty) {
      lastWebPushError = 'config: FIREBASE_WEB_API_KEY пуст (сборка без secrets)';
      return WebPushRegistrationResult.notConfigured;
    }

    final permission = await requestWebNotificationPermission();
    if (permission == 'denied') {
      return WebPushRegistrationResult.permissionDenied;
    }
    if (permission != 'granted') {
      lastWebPushError = 'permission: не получено ($permission)';
      return WebPushRegistrationResult.permissionDenied;
    }

    String? token;
    Object? lastError;
    for (var attempt = 1; attempt <= 4; attempt++) {
      try {
        token = await getWebFcmToken(vapidKey)
            .timeout(const Duration(seconds: 30));
        if (token != null && token.isNotEmpty) break;
      } catch (e, st) {
        lastError = e;
        debugPrint('[FCM] getWebFcmToken attempt $attempt failed: $e\n$st');
      }
      if (attempt < 4) {
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        try {
          await ensureFcmServiceWorkerRegistered();
        } catch (_) {}
      }
    }
    if (token == null || token.isEmpty) {
      _failStep('getToken', lastError ?? 'пустой токен');
      return WebPushRegistrationResult.tokenFailed;
    }

    try {
      await repository.registerFcm(token: token, platform: 'web');
    } catch (e, st) {
      _failStep('registerFcm', e, st);
      return WebPushRegistrationResult.serverFailed;
    }

    listenWebPushIncomingCalls();
    await initWebFcmForeground();

    return WebPushRegistrationResult.success;
  }

  static Future<void> _wireHandlers(
    FirebaseMessaging messaging,
    FamilyChatRepository repository, {
    required String platform,
  }) async {
    if (_wired) return;

    if (_wireLock != null) {
      await _wireLock;
      return;
    }

    final completer = Completer<void>();
    _wireLock = completer.future;
    try {
      _onMessageSub ??= FirebaseMessaging.onMessage.listen(
        (message) => handleFamilyChatRemoteMessage(message),
      );
      _onMessageOpenedSub ??= FirebaseMessaging.onMessageOpenedApp.listen(
        (message) =>
            handleFamilyChatRemoteMessage(message, openedFromTap: true),
      );
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        handleFamilyChatRemoteMessage(initial, openedFromTap: true);
      }
      _onTokenRefreshSub ??= messaging.onTokenRefresh.listen((t) async {
        if (t.isNotEmpty) {
          await repository.registerFcm(token: t, platform: platform);
        }
      });
      _wired = true;
    } catch (e, st) {
      _wired = false;
      _failStep('wireHandlers', e, st);
      rethrow;
    } finally {
      if (!completer.isCompleted) completer.complete();
      _wireLock = null;
    }
  }
}
