import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

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
    } catch (_) {
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

  static Future<void> registerIfPossible({
    required ApiClient client,
    required FamilyChatRepository repository,
  }) async {
    if (kIsWeb) {
      if (isIosBrowser && !isStandalonePwa) return;
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _registerAndroid(repository);
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

  static Future<void> _registerAndroid(FamilyChatRepository repository) async {
    final permission = await Permission.notification.status;
    if (!permission.isGranted && !permission.isPermanentlyDenied) {
      await Permission.notification.request();
    }

    await ensureFirebaseInitialized();
    if (Firebase.apps.isEmpty) return;

    if (!await Permission.notification.isGranted) return;

    final messaging = FirebaseMessaging.instance;
    final token = await messaging.getToken();
    if (token != null && token.isNotEmpty) {
      await repository.registerFcm(token: token, platform: 'android');
    }
    _wireHandlers(messaging, repository, platform: 'android');
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
