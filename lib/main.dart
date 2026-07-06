import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/bootstrap_screen.dart';
import 'core/push/push_message_handler.dart';
import 'core/push/push_navigation.dart';
import 'core/push/push_registration_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru', null);
  if (kIsWeb) {
    usePathUrlStrategy();
  } else {
    try {
      await PushRegistrationService.ensureFirebaseInitialized();
    } catch (e) {
      debugPrint('[FCM] init failed: $e');
    }
    FirebaseMessaging.onBackgroundMessage(familychatFirebaseBackgroundHandler);
  }
  runApp(const ProviderScope(child: FamilyChatApp()));
}

class FamilyChatApp extends StatelessWidget {
  const FamilyChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Chat',
      navigatorKey: familyChatNavigatorKey,
      scaffoldMessengerKey: familyChatScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const BootstrapScreen(),
    );
  }
}
