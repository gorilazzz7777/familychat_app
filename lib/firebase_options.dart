import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Firebase (FCM). Web — --dart-define при сборке; Android — google-services.json.
class DefaultFirebaseOptions {
  static FirebaseOptions? get currentPlatform {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return _androidOrNull;
    }

    const apiKey = String.fromEnvironment('FIREBASE_WEB_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_WEB_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

    if (apiKey.isEmpty ||
        appId.isEmpty ||
        senderId.isEmpty ||
        projectId.isEmpty) {
      return null;
    }

    const authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
    const storageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');

    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
      authDomain: authDomain.isEmpty ? '$projectId.firebaseapp.com' : authDomain,
      storageBucket: storageBucket.isEmpty
          ? '$projectId.appspot.com'
          : storageBucket,
    );
  }

  static FirebaseOptions? get _androidOrNull {
    const apiKey = String.fromEnvironment('FIREBASE_ANDROID_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

    if (apiKey.isEmpty ||
        appId.isEmpty ||
        senderId.isEmpty ||
        projectId.isEmpty) {
      return null;
    }

    const storageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');

    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
      storageBucket: storageBucket.isEmpty ? null : storageBucket,
    );
  }
}
