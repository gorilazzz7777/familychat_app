import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_actions_scope.dart';
import '../../../core/push/push_message_handler.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/appearance_prefs.dart';
import '../../../core/theme/theme_seed_controller.dart';
import '../../../core/theme/widgets/theme_color_picker_section.dart';
import '../../../core/widgets/family_app_bar.dart';

/// Экран оформления: настройки сверху, превью снизу всегда на экране.
class ThemeAppearanceScreen extends ConsumerStatefulWidget {
  const ThemeAppearanceScreen({
    super.key,
    this.onApplied,
  });

  final VoidCallback? onApplied;

  @override
  ConsumerState<ThemeAppearanceScreen> createState() =>
      _ThemeAppearanceScreenState();
}

class _ThemeAppearanceScreenState extends ConsumerState<ThemeAppearanceScreen> {
  late double _hue;
  late double? _fontScale;
  late String _wallpaperId;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _hue = AppTheme.hueFromSeedColor(ref.read(themeSeedProvider));
    _fontScale = ref.read(appearanceFontScaleProvider);
    _wallpaperId = ref.read(chatWallpaperIdProvider);
  }

  Color get _draftSeed => AppTheme.seedColorFromHue(_hue);

  Future<void> _save() async {
    setState(() => _applying = true);
    try {
      await ref.read(themeSeedProvider.notifier).applyAndSave(_draftSeed);
      await ref.read(appearanceFontScaleProvider.notifier).setScale(_fontScale);
      await ref.read(chatWallpaperIdProvider.notifier).setId(_wallpaperId);
      if (!mounted) return;
      widget.onApplied?.call();
      final navigator = Navigator.of(context);
      navigator.pop();
      navigator.pop();
      AppActions.openChatTab();
      familyChatScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Оформление сохранено')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      appBar: FamilyAppBar.build(title: 'Оформление'),
      body: Column(
        children: [
          Expanded(
            child: ThemeAppearanceSettingsPanel(
              hue: _hue,
              onHueChanged: (v) => setState(() => _hue = v),
              fontScale: _fontScale,
              onFontScaleChanged: (v) => setState(() => _fontScale = v),
              wallpaperId: _wallpaperId,
              onWallpaperChanged: (v) => setState(() => _wallpaperId = v),
            ),
          ),
          ThemeAppearancePreviewPanel(
            seedColor: _draftSeed,
            fontScale: _fontScale,
            wallpaperId: _wallpaperId,
            applying: _applying,
            onSave: _save,
          ),
        ],
      ),
    );
  }
}
