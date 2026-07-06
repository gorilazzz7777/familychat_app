import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/platform/browser_info.dart';
import '../core/providers/app_providers.dart';
import '../core/push/push_registration_service.dart';

/// На web (особенно iOS PWA) push включается по кнопке — нужен user gesture.
class WebPushPrompt extends ConsumerStatefulWidget {
  const WebPushPrompt({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WebPushPrompt> createState() => _WebPushPromptState();
}

class _WebPushPromptState extends ConsumerState<WebPushPrompt> {
  static const _prefKey = 'familychat_web_push_prompt_dismissed';
  static const _registeredKey = 'familychat_web_push_registered';

  bool _visible = false;
  bool _busy = false;
  String _permission = 'default';
  String? _inlineMessage;
  bool _inlineError = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (!kIsWeb) return;
    if (!webNotificationsSupported) return;
    if (isIosBrowser && !isStandalonePwa) return;

    final permission = webNotificationPermission;
    final prefs = await SharedPreferences.getInstance();
    final registered = prefs.getBool(_registeredKey) == true;

    if (permission == 'granted' && registered) {
      if (mounted) setState(() => _visible = false);
      return;
    }

    if (permission == 'denied' && prefs.getBool(_prefKey) == true) {
      if (mounted) setState(() => _visible = false);
      return;
    }

    if (!mounted) return;
    setState(() {
      _permission = permission;
      _visible = true;
    });
  }

  String get _description {
    if (_permission == 'granted') {
      return 'Разрешение уже дано. Нажмите «Включить», чтобы завершить подключение push.';
    }
    if (_permission == 'denied') {
      return 'Уведомления запрещены. Откройте Настройки iPhone → '
          'Уведомления → Family Chat и включите «Разрешить уведомления». '
          'Затем вернитесь сюда и нажмите «Включить» снова.';
    }
    return 'Получайте сообщения из чатов, даже когда приложение закрыто.';
  }

  Future<void> _enable() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _inlineMessage = null;
      _inlineError = false;
    });
    try {
      final result = await PushRegistrationService.registerWebPush(
        ref.read(familychatRepositoryProvider),
      );
      if (!mounted) return;

      switch (result) {
        case WebPushRegistrationResult.success:
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_registeredKey, true);
          if (!mounted) return;
          setState(() {
            _inlineMessage = 'Уведомления включены';
            _inlineError = false;
          });
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          if (mounted) setState(() => _visible = false);
        case WebPushRegistrationResult.permissionDenied:
          await _refresh();
          if (!mounted) return;
          setState(() {
            _inlineMessage = 'Доступ не дан. Включите уведомления в настройках iPhone.';
            _inlineError = true;
          });
        case WebPushRegistrationResult.notConfigured:
          setState(() {
            _inlineMessage =
                'Сервис уведомлений временно недоступен. Обновите страницу позже.';
            _inlineError = true;
          });
        case WebPushRegistrationResult.tokenFailed:
          setState(() {
            _inlineMessage = _formatError(
              'Не удалось получить токен push. Удалите PWA с экрана «Домой», '
              'добавьте заново через Safari и попробуйте ещё раз.',
            );
            _inlineError = true;
          });
        case WebPushRegistrationResult.serverFailed:
          setState(() {
            _inlineMessage = _formatError(
              'Токен получен, но сервер не принял регистрацию. Проверьте интернет и повторите.',
            );
            _inlineError = true;
          });
        case WebPushRegistrationResult.failed:
          setState(() {
            _inlineMessage = _formatError('Не удалось подключить. Попробуйте ещё раз.');
            _inlineError = true;
          });
      }
    } catch (e) {
      if (!mounted) return;
      PushRegistrationService.lastWebPushError = e.toString();
      setState(() {
        _inlineMessage = _formatError('Не удалось подключить. Попробуйте ещё раз.');
        _inlineError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatError(String fallback) {
    final detail = PushRegistrationService.lastWebPushError?.trim();
    if (detail == null || detail.isEmpty) return fallback;
    final short = detail.length > 160 ? '${detail.substring(0, 160)}…' : detail;
    return '$fallback\n\nТехнически: $short';
  }

  Future<void> _dismiss() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, true);
    if (mounted) setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(height: 1.45);
    final bottomInset =
        MediaQuery.paddingOf(context).bottom + kBottomNavigationBarHeight + 8;

    return Stack(
      children: [
        widget.child,
        if (_visible)
          Positioned(
            left: 12,
            right: 12,
            bottom: bottomInset,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Push-уведомления',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_description, style: bodyStyle),
                    if (_inlineMessage != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _inlineMessage!,
                        style: bodyStyle?.copyWith(
                          color: _inlineError
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : _dismiss,
                          child: const Text('Не сейчас'),
                        ),
                        FilledButton(
                          onPressed: _busy ? null : _enable,
                          child: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Включить'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
