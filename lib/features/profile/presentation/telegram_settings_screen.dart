import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_actions_scope.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../telegram_tdlib/presentation/telegram_phone_input.dart';
import '../../telegram_tdlib/tdlib_config.dart';
import '../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../telegram_tdlib/telegram_tdlib_service.dart';

/// Логин Telegram через TDLib (номер → код → 2FA).
class TelegramSettingsScreen extends ConsumerStatefulWidget {
  const TelegramSettingsScreen({super.key});

  @override
  ConsumerState<TelegramSettingsScreen> createState() =>
      _TelegramSettingsScreenState();
}

class _TelegramSettingsScreenState
    extends ConsumerState<TelegramSettingsScreen> {
  final _phoneInputKey = GlobalKey<TelegramPhoneInputState>();
  final _codeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  String _phoneE164 = '';
  bool _busy = false;
  String? _localError;
  bool _leftAfterConnect = false;
  TdlibAuthPhase? _lastSeenPhase;

  static const _authPhases = {
    TdlibAuthPhase.starting,
    TdlibAuthPhase.waitPhone,
    TdlibAuthPhase.waitCode,
    TdlibAuthPhase.waitPassword,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        ref.read(telegramTdlibServiceProvider).ensureStarted(),
      );
    });
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      final svc = ref.read(telegramTdlibServiceProvider);
      if (svc.phase == TdlibAuthPhase.starting) {
        unawaited(svc.ensureStarted());
      }
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _goToTelegramChatsAfterConnect() {
    if (_leftAfterConnect || !mounted) return;
    _leftAfterConnect = true;
    AppActions.openTelegramChatsTab();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _localError = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _localError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitPhone() async {
    final phone =
        _phoneInputKey.currentState?.e164.trim() ?? _phoneE164.trim();
    if (phone.length < 8) {
      setState(() => _localError = 'Введите полный номер телефона');
      return;
    }
    await _run(() => ref.read(telegramTdlibServiceProvider).submitPhone(phone));
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(telegramTdlibServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    final err = _localError ?? svc.errorMessage;

    // ChangeNotifier: same instance — track phase ourselves.
    final prev = _lastSeenPhase;
    final phase = svc.phase;
    if (!_leftAfterConnect &&
        prev != null &&
        _authPhases.contains(prev) &&
        phase == TdlibAuthPhase.ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _goToTelegramChatsAfterConnect();
      });
    }
    _lastSeenPhase = phase;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Telegram'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (!TdlibConfig.isSupportedPlatform)
            _banner(
              scheme,
              'На этой платформе TDLib не подключён. Поддерживаются Android и iOS.',
            )
          else if (!TdlibConfig.hasApiCredentials)
            _banner(
              scheme,
              'Нет Telegram API credentials (см. docs/TDLIB.md).',
            ),
          const SizedBox(height: 12),
          Text(
            _statusLabel(svc.phase),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (err != null && err.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(err, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 20),
          if (svc.phase == TdlibAuthPhase.starting) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            const Text('Инициализация Telegram…', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                        () => svc.ensureStarted(forceRestart: true),
                      ),
              child: const Text('Сбросить и повторить'),
            ),
          ],
          if (svc.phase == TdlibAuthPhase.waitPhone) ...[
            TelegramPhoneInput(
              key: _phoneInputKey,
              enabled: !_busy && TdlibConfig.isEnabled,
              onChanged: (v) => _phoneE164 = v,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: (!_busy && TdlibConfig.isEnabled) ? _submitPhone : null,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Получить код'),
            ),
          ],
          if (svc.phase == TdlibAuthPhase.error ||
              svc.phase == TdlibAuthPhase.unavailable) ...[
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                        () => svc.ensureStarted(forceRestart: true),
                      ),
              child: const Text('Повторить'),
            ),
          ],
          if (svc.phase == TdlibAuthPhase.waitCode) ...[
            Text(
              svc.codeViaApp
                  ? 'Код придёт в приложение Telegram'
                  : 'Введите код из SMS',
            ),
            if (svc.phoneHint != null)
              Text(svc.phoneHint!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Код',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => svc.submitCode(_codeCtrl.text)),
              child: const Text('Подтвердить'),
            ),
          ],
          if (svc.phase == TdlibAuthPhase.waitPassword) ...[
            const Text('Облачный пароль 2FA'),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Пароль',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => svc.submitPassword(_passwordCtrl.text)),
              child: const Text('Войти'),
            ),
          ],
          if (svc.phase == TdlibAuthPhase.ready) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(LucideIcons.circle_check, color: scheme.primary),
              title: const Text('Telegram подключён'),
              subtitle: const Text('Чаты во вкладке «Telegram».'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                AppActions.openTelegramChatsTab();
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              child: const Text('Открыть чаты Telegram'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(svc.logOut),
              child: const Text('Отключить'),
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(TdlibAuthPhase phase) {
    return switch (phase) {
      TdlibAuthPhase.unavailable => 'Недоступно',
      TdlibAuthPhase.starting => 'Запуск…',
      TdlibAuthPhase.waitPhone => 'Введите номер',
      TdlibAuthPhase.waitCode => 'Введите код',
      TdlibAuthPhase.waitPassword => 'Двухфакторная защита',
      TdlibAuthPhase.ready => 'Готово',
      TdlibAuthPhase.loggingOut => 'Выход…',
      TdlibAuthPhase.error => 'Ошибка',
    };
  }

  Widget _banner(ColorScheme scheme, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text),
    );
  }
}
