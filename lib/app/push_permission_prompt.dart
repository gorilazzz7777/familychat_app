import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/providers/app_providers.dart';
import '../core/push/push_registration_service.dart';
import '../features/familychat/data/familychat_repository.dart';

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
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return _PushPermissionAskDialog(
          description: _description(status, permanentlyDenied),
          permanentlyDenied: permanentlyDenied,
          onDismiss: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(_prefKey, true);
            if (ctx.mounted) Navigator.pop(ctx);
          },
          onOpenSettings: () async {
            await PushRegistrationService.openNotificationSettings();
            if (ctx.mounted) Navigator.pop(ctx);
          },
          onAllow: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            final repository = ref.read(familychatRepositoryProvider);
            final granted = await PushRegistrationService.requestOsPermission();
            if (!ctx.mounted) return false;
            if (!granted) {
              messenger?.showSnackBar(
                const SnackBar(
                  content: Text('Разрешение на уведомления не получено'),
                ),
              );
              return false;
            }
            Navigator.pop(ctx);
            unawaited(_registerPushInBackground(messenger, repository));
            return true;
          },
        );
      },
    );
  }

  Future<void> _registerPushInBackground(
    ScaffoldMessengerState? messenger,
    FamilyChatRepository repository,
  ) async {
    final result =
        await PushRegistrationService.registerGrantedToken(repository);
    if (result == WebPushRegistrationResult.success) {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_registeredKey, true);
      }
      messenger?.showSnackBar(
        const SnackBar(content: Text('Уведомления включены')),
      );
      return;
    }
    if (result == WebPushRegistrationResult.notConfigured) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            PushRegistrationService.lastWebPushError ??
                'Push временно недоступен. Попробуйте позже.',
          ),
        ),
      );
      return;
    }
    final detail = PushRegistrationService.lastWebPushError;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          detail != null && detail.isNotEmpty
              ? 'Не удалось включить уведомления: $detail'
              : 'Не удалось включить уведомления',
        ),
      ),
    );
  }

  String _description(PushPermissionStatus status, bool permanentlyDenied) {
    if (kIsWeb) {
      if (status == PushPermissionStatus.denied) {
        return 'Уведомления запрещены. Откройте Настройки iPhone → '
            'Уведомления → Family Space и включите «Разрешить уведомления», '
            'затем нажмите «Повторить».';
      }
      return 'Разрешите уведомления, чтобы получать новые сообщения из чатов, '
          'даже когда приложение закрыто.';
    }

    if (permanentlyDenied) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return 'Уведомления отключены. Откройте Настройки → Family Space → '
            'Уведомления и включите «Разрешить уведомления».';
      }
      return 'Уведомления отключены в настройках. Откройте настройки '
          'приложения Family Space и включите уведомления.';
    }

    return 'Разрешите уведомления, чтобы не пропускать новые сообщения в семейных '
        'и личных чатах.';
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PushPermissionAskDialog extends StatefulWidget {
  const _PushPermissionAskDialog({
    required this.description,
    required this.permanentlyDenied,
    required this.onDismiss,
    required this.onOpenSettings,
    required this.onAllow,
  });

  final String description;
  final bool permanentlyDenied;
  final Future<void> Function() onDismiss;
  final Future<void> Function() onOpenSettings;
  final Future<bool> Function() onAllow;

  @override
  State<_PushPermissionAskDialog> createState() =>
      _PushPermissionAskDialogState();
}

class _PushPermissionAskDialogState extends State<_PushPermissionAskDialog> {
  bool _busy = false;

  Future<void> _handleAllow() async {
    if (_busy) return;
    setState(() => _busy = true);
    final closed = await widget.onAllow();
    if (!closed && mounted) {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    return AlertDialog(
      title: const Text('Уведомления'),
      content: Text(widget.description),
      actions: [
        TextButton(
          onPressed: _busy ? null : widget.onDismiss,
          child: const Text('Не сейчас'),
        ),
        if (widget.permanentlyDenied)
          FilledButton(
            onPressed: _busy ? null : widget.onOpenSettings,
            child: const Text('Настройки'),
          )
        else
          FilledButton(
            onPressed: _handleAllow,
            child: _busy
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: onPrimary,
                    ),
                  )
                : const Text('Разрешить'),
          ),
      ],
    );
  }
}
