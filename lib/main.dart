import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/bootstrap_screen.dart';
import 'core/notifications/familychat_notifications.dart';
import 'core/push/push_message_handler.dart';
import 'core/push/push_navigation.dart';
import 'core/push/push_registration_service.dart';
import 'core/share/incoming_share_bus.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_seed_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Не блокируем первый кадр: даты и Firebase догружаются параллельно.
  unawaited(initializeDateFormatting('ru', null));
  if (kIsWeb) {
    usePathUrlStrategy();
  } else {
    unawaited(() async {
      try {
        await PushRegistrationService.ensureFirebaseInitialized();
      } catch (e) {
        debugPrint('[FCM] init failed: $e');
      }
    }());
    FirebaseMessaging.onBackgroundMessage(familychatFirebaseBackgroundHandler);
    unawaited(FamilyChatNotifications.initialize());
    unawaited(IncomingShareBus.instance.init());
  }
  runApp(const ProviderScope(child: FamilyChatApp()));
}

class FamilyChatApp extends ConsumerWidget {
  const FamilyChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seedColor = ref.watch(themeSeedProvider);

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
      theme: AppTheme.lightTheme(seedColor),
      home: const BootstrapScreen(),
    );
  }
}
