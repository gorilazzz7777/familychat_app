import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Firebase (FCM).
/// Web — --dart-define при сборке.
/// Android — google-services.json / встроенные значения.
/// iOS — GoogleService-Info.plist или --dart-define (FIREBASE_IOS_*).
class DefaultFirebaseOptions {
  static FirebaseOptions? get currentPlatform {
    if (kIsWeb) {
      return _fromWebDefines();
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        return null;
    }
  }

  static FirebaseOptions? _fromWebDefines() {
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

  /// Android: dart-define при CI или значения из android/app/google-services.json.
  static FirebaseOptions get android {
    const apiKey = String.fromEnvironment('FIREBASE_ANDROID_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

    if (apiKey.isNotEmpty &&
        appId.isNotEmpty &&
        senderId.isNotEmpty &&
        projectId.isNotEmpty) {
      const storageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
      return FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: senderId,
        projectId: projectId,
        storageBucket: storageBucket.isEmpty ? null : storageBucket,
      );
    }

    return const FirebaseOptions(
      apiKey: 'AIzaSyA0-_aY8ZiCTRYTfD0SblLuWu4LusDAOuo',
      appId: '1:156229477633:android:baede981ed6d8023b46700',
      messagingSenderId: '156229477633',
      projectId: 'familychat-53a64',
      storageBucket: 'familychat-53a64.firebasestorage.app',
    );
  }

  /// iOS: dart-define или `null` → Firebase.initializeApp() читает GoogleService-Info.plist.
  static FirebaseOptions? get ios {
    const apiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
    const appId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

    if (apiKey.isEmpty ||
        appId.isEmpty ||
        senderId.isEmpty ||
        projectId.isEmpty) {
      return null;
    }

    const storageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
    const iosBundleId = String.fromEnvironment(
      'FIREBASE_IOS_BUNDLE_ID',
      defaultValue: 'com.familychat.familychatApp',
    );

    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
      storageBucket: storageBucket.isEmpty
          ? 'familychat-53a64.firebasestorage.app'
          : storageBucket,
      iosBundleId: iosBundleId,
    );
  }
}
