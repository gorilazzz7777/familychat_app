import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/family_app_bar.dart';
import '../telegram_tdlib_providers.dart';
import '../telegram_tdlib_service.dart';

/// Режим FakeTLS / MTProto-прокси для Telegram.
class TelegramProxySettingsScreen extends ConsumerWidget {
  const TelegramProxySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = ref.watch(telegramTdlibServiceProvider);
    final mode = svc.mtprotoProxyMode;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Прокси'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            'Режим',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          _ModeTile(
            title: 'Авто',
            subtitle:
                'Как сейчас: в России прокси включается, при VPN или за рубежом — выключается',
            selected: mode == TdlibMtprotoProxyMode.auto,
            onTap: () => unawaited(
              svc.setMtprotoProxyMode(TdlibMtprotoProxyMode.auto),
            ),
          ),
          _ModeTile(
            title: 'Включен',
            subtitle: 'Всегда включен, даже при VPN',
            selected: mode == TdlibMtprotoProxyMode.alwaysOn,
            onTap: () => unawaited(
              svc.setMtprotoProxyMode(TdlibMtprotoProxyMode.alwaysOn),
            ),
          ),
          _ModeTile(
            title: 'Выключен',
            subtitle: 'Всегда выключен',
            selected: mode == TdlibMtprotoProxyMode.alwaysOff,
            onTap: () => unawaited(
              svc.setMtprotoProxyMode(TdlibMtprotoProxyMode.alwaysOff),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
