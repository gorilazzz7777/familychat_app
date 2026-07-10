import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/theme_seed_controller.dart';
import '../../../core/theme/widgets/theme_color_picker_section.dart';
import '../../../core/widgets/family_app_bar.dart';

/// Экран выбора цвета темы (отдельно от профиля, без конфликта со свайпом табов).
class ThemeAppearanceScreen extends ConsumerWidget {
  const ThemeAppearanceScreen({
    super.key,
    this.onApplied,
  });

  final VoidCallback? onApplied;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Оформление'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          ThemeColorPickerBody(
            currentSeedColor: ref.watch(themeSeedProvider),
            onApply: (seed) async {
              await ref.read(themeSeedProvider.notifier).applyAndSave(seed);
              onApplied?.call();
            },
          ),
        ],
      ),
    );
  }
}
