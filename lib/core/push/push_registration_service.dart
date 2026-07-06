import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../network/api_client.dart';
import '../../features/familychat/data/familychat_repository.dart';

class PushRegistrationService {
  static Future<void> ensureFirebaseInitialized() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  }

  static Future<void> registerIfPossible({
    required ApiClient client,
    required FamilyChatRepository repository,
  }) async {
    if (kIsWeb) return;
    try {
      await ensureFirebaseInitialized();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token == null || token.isEmpty) return;
      await repository.registerFcm(token: token, platform: defaultTargetPlatform.name);
    } catch (e) {
      debugPrint('[FCM] familychat register failed: $e');
    }
  }
}

@pragma('vm:entry-point')
Future<void> familychatFirebaseBackgroundHandler(RemoteMessage message) async {
  await PushRegistrationService.ensureFirebaseInitialized();
}
