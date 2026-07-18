import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/providers/app_providers.dart';
import '../core/push/push_registration_service.dart';

/// После авторизации проверяет разрешение на push и просит включить уведомления.
class PushPermissionPrompt extends ConsumerStatefulWidget {
  const PushPermissionPrompt({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PushPermissionPrompt> createState() => _PushPermissionPromptState();
}

class _PushPermissionPromptState extends ConsumerState<PushPermissionPrompt> {
  static const _prefKey = 'familychat_push_prompt_dismissed';
  static const _registeredKey = 'familychat_web_push_registered';

  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkAfterLogin());
    });
  }

  Future<void> _checkAfterLogin() async {
    if (!mounted) return;
    if (!await PushRegistrationService.isPushSupported()) return;

    final status = await PushRegistrationService.getPushPermissionStatus();
    if (status == PushPermissionStatus.granted) {
      final ok = await PushRegistrationService.registerIfPossible(
        client: ref.read(apiClientProvider),
        repository: ref.read(familychatRepositoryProvider),
      );
      if (!ok && mounted) {
        final err = PushRegistrationService.lastWebPushError;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              err != null && err.isNotEmpty
                  ? 'Не удалось зарегистрировать push: $err'
                  : 'Не удалось зарегистрировать push-уведомления',
            ),
          ),
        );
      }
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefKey) == true) return;
    if (!mounted || _dialogShown) return;

    _dialogShown = true;
    await _showPermissionDialog(status);
  }

  Future<void> _showPermissionDialog(PushPermissionStatus status) async {
    if (!mounted) return;

    final permanentlyDenied = !kIsWeb &&
        await PushRegistrationService.isNativePermissionPermanentlyDenied();

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Уведомления'),
          content: Text(_description(status, permanentlyDenied)),
          actions: [
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(_prefKey, true);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Не сейчас'),
            ),
            if (permanentlyDenied)
              FilledButton(
                onPressed: () async {
                  await PushRegistrationService.openNotificationSettings();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Настройки'),
              )
            else
              FilledButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  final result = await PushRegistrationService.requestPushAfterLogin(
                    ref.read(familychatRepositoryProvider),
                  );
                  if (!ctx.mounted) return;

                  if (result == WebPushRegistrationResult.success) {
                    final prefs = await SharedPreferences.getInstance();
                    if (kIsWeb) {
                      await prefs.setBool(_registeredKey, true);
                    }
                    Navigator.pop(ctx);
                    messenger?.showSnackBar(
                      const SnackBar(content: Text('Уведомления включены')),
                    );
                    return;
                  }

                  if (result == WebPushRegistrationResult.permissionDenied) {
                    messenger?.showSnackBar(
                      const SnackBar(
                        content: Text('Разрешение на уведомления не получено'),
                      ),
                    );
                  } else if (result == WebPushRegistrationResult.notConfigured) {
                    messenger?.showSnackBar(
                      const SnackBar(
                        content: Text('Push временно недоступен. Попробуйте позже.'),
                      ),
                    );
                  } else {
                    messenger?.showSnackBar(
                      const SnackBar(
                        content: Text('Не удалось включить уведомления'),
                      ),
                    );
                  }
                },
                child: const Text('Разрешить'),
              ),
          ],
        );
      },
    );
  }

  String _description(PushPermissionStatus status, bool permanentlyDenied) {
    if (kIsWeb) {
      if (status == PushPermissionStatus.denied) {
        return 'Уведомления запрещены. Откройте Настройки iPhone → '
            'Уведомления → Family Chat и включите «Разрешить уведомления», '
            'затем нажмите «Повторить».';
      }
      return 'Разрешите уведомления, чтобы получать новые сообщения из чатов, '
          'даже когда приложение закрыто.';
    }

    if (permanentlyDenied) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return 'Уведомления отключены. Откройте Настройки → Family Chat → '
            'Уведомления и включите «Разрешить уведомления».';
      }
      return 'Уведомления отключены в настройках. Откройте настройки '
          'приложения Family Chat и включите уведомления.';
    }

    return 'Разрешите уведомления, чтобы не пропускать новые сообщения в семейных '
        'и личных чатах.';
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
