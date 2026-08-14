import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/settings/app_settings_controller.dart';
import '../../../core/widgets/family_app_bar.dart';

class MenuSectionsScreen extends ConsumerStatefulWidget {
  const MenuSectionsScreen({super.key});

  @override
  ConsumerState<MenuSectionsScreen> createState() => _MenuSectionsScreenState();
}

class _MenuSectionsScreenState extends ConsumerState<MenuSectionsScreen> {
  bool _busy = false;

  Future<void> _apply(FamilyChatAppSettings next) async {
    setState(() => _busy = true);
    try {
      await ref.read(appSettingsProvider.notifier).update(next);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Разделы меню'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Чат всегда остаётся. Если остальные разделы выключить, '
            'нижняя панель скроется.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Чат'),
            subtitle: const Text('Обязательный раздел'),
            value: true,
            onChanged: null,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Лента'),
            value: settings.menuFeed,
            onChanged:
                _busy ? null : (v) => _apply(settings.copyWith(menuFeed: v)),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Семья'),
            subtitle: const Text(
              'Если скрыть, раздел останется в профиле — кнопка «Семья»',
            ),
            value: settings.menuFamily,
            onChanged:
                _busy ? null : (v) => _apply(settings.copyWith(menuFamily: v)),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Галерея'),
            value: settings.menuGallery,
            onChanged: _busy
                ? null
                : (v) => _apply(settings.copyWith(menuGallery: v)),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Календарь'),
            value: settings.menuCalendar,
            onChanged: _busy
                ? null
                : (v) => _apply(settings.copyWith(menuCalendar: v)),
          ),
        ],
      ),
    );
  }
}
