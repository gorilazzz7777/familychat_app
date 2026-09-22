import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_actions_scope.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';

/// Настройки Telegram Secretary (только Individual Premium).
class TelegramSettingsScreen extends ConsumerStatefulWidget {
  const TelegramSettingsScreen({super.key});

  @override
  ConsumerState<TelegramSettingsScreen> createState() =>
      _TelegramSettingsScreenState();
}

class _TelegramSettingsScreenState
    extends ConsumerState<TelegramSettingsScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;
  bool _setupMode = false;
  bool _step1Expanded = true;
  bool _step2Expanded = false;

  bool get _step1Done {
    final p = _payload;
    if (p == null) return false;
    final tg = p['tg_user_id'];
    return tg != null || p['connected'] == true;
  }

  bool get _step2Done => _payload?['business_connected'] == true;

  bool get _fullyConnected => _step1Done && _step2Done;

  bool get _isGrace => _payload?['status']?.toString() == 'grace';

  String get _botUsername {
    final raw = _payload?['bot_username']?.toString().trim() ?? '';
    if (raw.isEmpty) return '';
    return raw.startsWith('@') ? raw : '@$raw';
  }

  String get _deepLink => _payload?['deep_link']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload({bool keepSetup = false, bool silent = false}) async {
    if (!silent || _payload == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .telegramConnectionStart();
      if (!mounted) return;
      setState(() {
        _payload = data;
        _loading = false;
        _error = null;
        final linked = data['tg_user_id'] != null || data['connected'] == true;
        final business = data['business_connected'] == true;
        if (linked && business) {
          if (!keepSetup) _setupMode = false;
        } else if (keepSetup || linked || business) {
          _setupMode = true;
          _syncExpandedSteps();
        }
      });
      unawaited(AppActions.refreshStatus());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _syncExpandedSteps() {
    if (!_step1Done) {
      _step1Expanded = true;
      _step2Expanded = false;
    } else if (!_step2Done) {
      _step1Expanded = false;
      _step2Expanded = true;
    } else {
      _step1Expanded = false;
      _step2Expanded = false;
    }
  }

  void _enterSetup() {
    setState(() {
      _setupMode = true;
      _syncExpandedSteps();
    });
  }

  Future<void> _openDeepLink() async {
    final link = _deepLink;
    if (link.isEmpty) return;
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyBotUsername() async {
    final name = _botUsername;
    if (name.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: name));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Скопировано: $name')),
    );
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отключить Telegram?'),
        content: const Text(
          'Новые сообщения из Telegram перестанут приходить в Family Space. '
          'История в чатах Family Space сохранится.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Отключить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(familychatRepositoryProvider).telegramConnectionDisconnect();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final showHowItWorks = _fullyConnected && !_setupMode && !_loading;

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Telegram',
        actions: [
          if (showHowItWorks)
            IconButton(
              tooltip: 'Как это работает',
              icon: const Icon(LucideIcons.circle_question_mark),
              onPressed: _enterSetup,
            ),
        ],
      ),
      body: _loading && _payload == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _reload(
                keepSetup: _setupMode,
                silent: true,
              ),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_fullyConnected && !_setupMode)
                    _ConnectedView(
                      isGrace: _isGrace,
                      graceUntil: _payload?['grace_until']?.toString(),
                      tgUsername: _payload?['tg_username']?.toString() ?? '',
                      canWrite: _payload?['can_write'] == true,
                      onDisconnect: _disconnect,
                    )
                  else if (_setupMode)
                    _SetupView(
                      step1Done: _step1Done,
                      step2Done: _step2Done,
                      step1Expanded: _step1Expanded,
                      step2Expanded: _step2Expanded,
                      botUsername: _botUsername,
                      showBackToConnected: _fullyConnected,
                      onBackToConnected: () =>
                          setState(() => _setupMode = false),
                      onToggleStep1: () =>
                          setState(() => _step1Expanded = !_step1Expanded),
                      onToggleStep2: () =>
                          setState(() => _step2Expanded = !_step2Expanded),
                      onOpenBot: _openDeepLink,
                      onCopyBot: _copyBotUsername,
                    )
                  else
                    _LandingView(onConnect: _enterSetup),
                ],
              ),
            ),
    );
  }
}

class _LandingView extends StatelessWidget {
  const _LandingView({required this.onConnect});

  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Icon(
          LucideIcons.send,
          size: 44,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Чаты Telegram в Family Space',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'Подключите бота Family Space к своему Telegram — личные '
          'сообщения будут появляться здесь, а отвечать можно прямо '
          'из приложения.',
          style: theme.textTheme.bodyLarge?.copyWith(color: muted, height: 1.35),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        _FeatureRow(
          icon: LucideIcons.message_circle,
          text: 'Новые сообщения из выбранных чатов Telegram',
        ),
        _FeatureRow(
          icon: LucideIcons.reply,
          text: 'Ответы уходят в Telegram от вашего имени',
        ),
        _FeatureRow(
          icon: LucideIcons.shield,
          text: 'Вы сами выбираете, к каким чатам есть доступ',
        ),
        const SizedBox(height: 8),
        Text(
          'История до подключения не загружается — только новые сообщения.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: onConnect,
          child: const Text('Подключить'),
        ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupView extends StatelessWidget {
  const _SetupView({
    required this.step1Done,
    required this.step2Done,
    required this.step1Expanded,
    required this.step2Expanded,
    required this.botUsername,
    required this.showBackToConnected,
    required this.onBackToConnected,
    required this.onToggleStep1,
    required this.onToggleStep2,
    required this.onOpenBot,
    required this.onCopyBot,
  });

  final bool step1Done;
  final bool step2Done;
  final bool step1Expanded;
  final bool step2Expanded;
  final String botUsername;
  final bool showBackToConnected;
  final VoidCallback onBackToConnected;
  final VoidCallback onToggleStep1;
  final VoidCallback onToggleStep2;
  final VoidCallback onOpenBot;
  final VoidCallback onCopyBot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doneCount = (step1Done ? 1 : 0) + (step2Done ? 1 : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBackToConnected)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onBackToConnected,
              icon: const Icon(LucideIcons.arrow_left),
              label: const Text('К статусу'),
            ),
          ),
        Text(
          'Подключение',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          doneCount == 0
              ? 'Два коротких шага — займёт пару минут'
              : 'Готово $doneCount из 2',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _SetupStepCard(
          number: 1,
          title: 'Связать Telegram и Family Space',
          done: step1Done,
          expanded: step1Expanded,
          onHeaderTap: onToggleStep1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Откройте бота Family Space в Telegram и нажмите Start. '
                'Именно эта кнопка привязывает ваш аккаунт — не пишите '
                '/start вручную.',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onOpenBot,
                icon: const Icon(LucideIcons.external_link),
                label: const Text('Открыть бота'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _SetupStepCard(
          number: 2,
          title: 'Подключить бота в Telegram',
          done: step2Done,
          expanded: step2Expanded,
          onHeaderTap: onToggleStep2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'В Telegram откройте свой профиль → карандаш (редактировать) → '
                'Автоматизация чатов. Добавьте бота Family Space и разрешите '
                'нужные личные чаты и право отвечать.',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: botUsername.isEmpty ? null : onCopyBot,
                icon: const Icon(LucideIcons.copy),
                label: Text(
                  botUsername.isEmpty
                      ? 'Скопировать имя бота'
                      : 'Скопировать $botUsername',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Если бота уже подключали до шага 1 — выключите и включите '
                'его снова в «Автоматизация чатов».',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Потяните вниз, чтобы обновить статус после шагов в Telegram.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _SetupStepCard extends StatelessWidget {
  const _SetupStepCard({
    required this.number,
    required this.title,
    required this.done,
    required this.expanded,
    required this.onHeaderTap,
    required this.child,
  });

  final int number;
  final String title;
  final bool done;
  final bool expanded;
  final VoidCallback onHeaderTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(14),
      child: Column(
        children: [
          InkWell(
            onTap: onHeaderTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
              child: Row(
                children: [
                  _StepBadge(number: number, done: done),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    expanded
                        ? LucideIcons.chevron_up
                        : LucideIcons.chevron_down,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: child,
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
          ),
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.number, required this.done});

  final int number;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (done) {
      return Icon(
        LucideIcons.circle_check,
        color: scheme.primary,
        size: 28,
      );
    }
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: scheme.primary, width: 1.5),
      ),
      child: Text(
        '$number',
        style: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.isGrace,
    required this.graceUntil,
    required this.tgUsername,
    required this.canWrite,
    required this.onDisconnect,
  });

  final bool isGrace;
  final String? graceUntil;
  final String tgUsername;
  final bool canWrite;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final error = theme.colorScheme.error;
    final statusText = isGrace
        ? 'Только чтение'
            '${graceUntil != null && graceUntil!.isNotEmpty ? ' до $graceUntil' : ''}'
        : (canWrite ? 'Подключено' : 'Подключено (без ответа)');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Center(
          child: Image.asset(
            'assets/logo/tg.png',
            width: 88,
            height: 88,
            filterQuality: FilterQuality.medium,
          ),
        ),
        const SizedBox(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            LucideIcons.circle_check,
            color: theme.colorScheme.primary,
            size: 32,
          ),
          title: Text(
            statusText,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            tgUsername.isEmpty
                ? 'Чаты появятся во вкладке Telegram по мере новых сообщений'
                : 'Telegram: @$tgUsername',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'История до подключения не загружается. Правки и удаления '
          'из Telegram пока не синхронизируются.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: 28),
        OutlinedButton.icon(
          onPressed: onDisconnect,
          style: OutlinedButton.styleFrom(
            foregroundColor: error,
            side: BorderSide(color: error.withValues(alpha: 0.55)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          icon: const Icon(LucideIcons.unlink, size: 18),
          label: const Text('Отключить'),
        ),
      ],
    );
  }
}
