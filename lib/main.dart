import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/bootstrap_screen.dart';
import 'core/call/callkit_incoming_service.dart';
import 'core/notifications/familychat_notifications.dart';
import 'core/push/push_message_handler.dart';
import 'core/push/push_navigation.dart';
import 'core/push/push_registration_service.dart';
import 'features/chat/data/incoming_call_coordinator.dart';
import 'core/share/incoming_share_bus.dart';
import 'core/media/media_local_index.dart';
import 'core/settings/screen_timeout_guard.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/appearance_prefs.dart';
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
    CallKitIncomingService.onAccepted = (extra, callId) async {
      openAcceptedCallFromPushData({
        'type': 'familychat_call_accepted',
        'session_id': '$callId',
        'thread_id': extra['thread_id']?.toString() ?? '',
        'caller_name': extra['caller_name']?.toString() ?? 'Family Space',
        'is_video': extra['is_video']?.toString() ?? '0',
      });
    };
    CallKitIncomingService.onEnded = (callId) async {
      IncomingCallCoordinator.instance.markHandled(callId);
    };
    unawaited(FamilyChatNotifications.initialize());
    unawaited(CallKitIncomingService.initialize());
    unawaited(IncomingShareBus.instance.init());
  }
  unawaited(MediaLocalIndex.ensureLoaded());
  runApp(const ProviderScope(child: FamilyChatApp()));
}

class FamilyChatApp extends ConsumerWidget {
  const FamilyChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seedColor = ref.watch(themeSeedProvider);
    final fontScale = ref.watch(appearanceFontScaleProvider);

    return MaterialApp(
      title: 'Family Space',
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
      builder: (context, child) {
        final content = ScreenTimeoutGuard(
          child: child ?? const SizedBox.shrink(),
        );
        MediaQueryData withFontScale(MediaQueryData mq) {
          if (fontScale == null) return mq;
          return mq.copyWith(textScaler: TextScaler.linear(fontScale));
        }

        if (!kIsWeb) {
          if (fontScale == null) return content;
          return MediaQuery(
            data: withFontScale(MediaQuery.of(context)),
            child: content,
          );
        }

        // Phone-width column on desktop so the UI does not stretch edge-to-edge.
        const maxWidth = 560.0;
        final mq = MediaQuery.of(context);
        if (mq.size.width <= maxWidth) {
          if (fontScale == null) return content;
          return MediaQuery(
            data: withFontScale(mq),
            child: content,
          );
        }

        final scheme = Theme.of(context).colorScheme;
        // Explicit height is required: Center alone gives unbounded height and
        // collapses Expanded/TabBarView (empty chat list, blank shell).
        return ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Center(
            child: SizedBox(
              width: maxWidth,
              height: mq.size.height,
              child: MediaQuery(
                data: withFontScale(
                  mq.copyWith(size: Size(maxWidth, mq.size.height)),
                ),
                child: ColoredBox(
                  color: scheme.surface,
                  child: content,
                ),
              ),
            ),
          ),
        );
      },
      home: const BootstrapScreen(),
    );
  }
}
