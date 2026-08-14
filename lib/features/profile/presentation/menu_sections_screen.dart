import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/settings/app_settings_controller.dart';
import '../../../core/settings/shell_nav_layout.dart';
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

  Future<void> _setVisible(ShellSection section, bool value) {
    final settings = ref.read(appSettingsProvider);
    final next = switch (section) {
      ShellSection.chat => settings,
      ShellSection.feed => settings.copyWith(menuFeed: value),
      ShellSection.family => settings.copyWith(menuFamily: value),
      ShellSection.gallery => settings.copyWith(menuGallery: value),
      ShellSection.calendar => settings.copyWith(menuCalendar: value),
    };
    if (section == ShellSection.chat) return Future.value();
    return _apply(next);
  }

  Future<void> _reorder(int oldIndex, int newIndex) {
    final settings = ref.read(appSettingsProvider);
    final order = ShellNavLayout.normalizedOrder(settings.menuOrder);
    if (newIndex > oldIndex) newIndex -= 1;
    final item = order.removeAt(oldIndex);
    order.insert(newIndex, item);
    return ref.read(appSettingsProvider.notifier).setMenuOrder(
          order.map((s) => s.name).toList(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider);
    final sections = ShellNavLayout.normalizedOrder(settings.menuOrder);

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Разделы меню'),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        buildDefaultDragHandles: false,
        header: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Чат всегда остаётся. Зажмите иконку в нижней панели и '
            'перетащите, чтобы поменять разделы местами.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        itemCount: sections.length,
        onReorder: _reorder,
        itemBuilder: (context, index) {
          final section = sections[index];
          final visible = ShellNavLayout.isVisible(section, settings);
          return ReorderableDelayedDragStartListener(
            key: ValueKey(section),
            index: index,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(ShellNavLayout.icon(section)),
              title: Text(ShellNavLayout.label(section)),
              subtitle: section == ShellSection.chat
                  ? const Text('Обязательный раздел')
                  : section == ShellSection.family
                      ? const Text(
                          'Если скрыть, раздел останется в профиле — кнопка «Семья»',
                        )
                      : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch.adaptive(
                    value: visible,
                    onChanged: section == ShellSection.chat || _busy
                        ? null
                        : (v) => _setVisible(section, v),
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.drag_handle,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
