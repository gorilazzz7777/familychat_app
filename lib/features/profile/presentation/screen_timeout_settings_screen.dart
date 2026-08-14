import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings_controller.dart';
import '../../../core/settings/screen_timeout.dart';
import '../../../core/widgets/family_app_bar.dart';

class ScreenTimeoutSettingsScreen extends ConsumerWidget {
  const ScreenTimeoutSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appSettingsProvider).screenTimeout;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Автоугасание экрана'),
      body: RadioGroup<ScreenTimeoutOption>(
        groupValue: current,
        onChanged: (next) {
          if (next == null) return;
          ref.read(appSettingsProvider.notifier).setScreenTimeout(next);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Пока приложение открыто. После ухода в фон действует '
                'системный таймаут телефона.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            for (final option in ScreenTimeoutOption.values)
              RadioListTile<ScreenTimeoutOption>(
                value: option,
                title: Text(option.label),
              ),
          ],
        ),
      ),
    );
  }
}
