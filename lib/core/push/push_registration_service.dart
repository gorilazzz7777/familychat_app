import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network/api_client.dart';
import '../platform/browser_info.dart';
import '../../features/familychat/data/familychat_repository.dart';
import '../../firebase_options.dart';
import 'web_fcm_service_worker.dart';
import 'web_fcm_token.dart';

@pragma('vm:entry-point')
Future<void> familychatFirebaseBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await PushRegistrationService.ensureFirebaseInitialized();
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
    return _registerGranted(repository);
  }

  /// Сброс состояния при выходе (повторная регистрация после нового входа).
  static void resetSession() {
    _wired = false;
    lastWebPushError = null;
  }

  static Future<bool> isPushSupported() async {
    if (kIsWeb) {
      if (!webNotificationsSupported) return false;
      if (isIosBrowser && !isStandalonePwa) return false;
      return true;
    }
    return defaultTargetPlatform == TargetPlatform.android;
  }

  static Future<PushPermissionStatus> getPushPermissionStatus() async {
    if (!await isPushSupported()) return PushPermissionStatus.unsupported;

    if (kIsWeb) {
      return switch (webNotificationPermission) {
        'granted' => PushPermissionStatus.granted,
        'denied' => PushPermissionStatus.denied,
        _ => PushPermissionStatus.notDetermined,
      };
    }

    final permission = await Permission.notification.status;
    if (permission.isGranted) return PushPermissionStatus.granted;
    if (permission.isPermanentlyDenied) return PushPermissionStatus.denied;
    return PushPermissionStatus.notDetermined;
  }

  static Future<bool> isAndroidPermissionPermanentlyDenied() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
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

    if (defaultTargetPlatform == TargetPlatform.android) {
      final permission = await Permission.notification.status;
      if (!permission.isGranted && !permission.isPermanentlyDenied) {
        await Permission.notification.request();
      }
      if (!await Permission.notification.isGranted) {
        return WebPushRegistrationResult.permissionDenied;
      }
      final ok = await _registerAndroid(repository, requestPermission: false);
      return ok ? WebPushRegistrationResult.success : WebPushRegistrationResult.serverFailed;
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
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _registerAndroid(repository, requestPermission: false);
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

  static Future<bool> _registerAndroid(
    FamilyChatRepository repository, {
    bool requestPermission = true,
  }) async {
    if (requestPermission) {
      final permission = await Permission.notification.status;
      if (!permission.isGranted && !permission.isPermanentlyDenied) {
        await Permission.notification.request();
      }
    }

    await ensureFirebaseInitialized();
    if (Firebase.apps.isEmpty) return false;

    if (!await Permission.notification.isGranted) return false;

    final messaging = FirebaseMessaging.instance;
    try {
      final token = await messaging.getToken();
      if (token == null || token.isEmpty) return false;
      await repository.registerFcm(token: token, platform: 'android');
      _wireHandlers(messaging, repository, platform: 'android');
      return true;
    } catch (e, st) {
      _failStep('registerFcm', e, st);
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

    return WebPushRegistrationResult.success;
  }

  static void _wireHandlers(
    FirebaseMessaging messaging,
    FamilyChatRepository repository, {
    required String platform,
  }) {
    if (_wired) return;
    _wired = true;

    messaging.onTokenRefresh.listen((t) async {
      if (t.isNotEmpty) {
        await repository.registerFcm(token: t, platform: platform);
      }
    });
  }
}
