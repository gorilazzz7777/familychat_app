import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../appearance_prefs.dart';
import '../../widgets/family_input_styles.dart';

/// Настройки оформления (без превью) — оттенок, шрифт, фон.
class ThemeAppearanceSettingsPanel extends StatelessWidget {
  const ThemeAppearanceSettingsPanel({
    super.key,
    required this.hue,
    required this.onHueChanged,
    required this.fontScale,
    required this.onFontScaleChanged,
    required this.wallpaperId,
    required this.onWallpaperChanged,
  });

  final double hue;
  final ValueChanged<double> onHueChanged;
  final double? fontScale;
  final ValueChanged<double?> onFontScaleChanged;
  final String wallpaperId;
  final ValueChanged<String> onWallpaperChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        _SettingsBlock(
          title: 'Оттенок',
          child: _HueGradientSlider(
            hue: hue,
            onChanged: onHueChanged,
          ),
        ),
        const SizedBox(height: 12),
        _SettingsBlock(
          title: 'Размер шрифта',
          child: _FontSizeSlider(
            fontScale: fontScale,
            onChanged: onFontScaleChanged,
          ),
        ),
        const SizedBox(height: 12),
        _CollapsibleSettingsBlock(
          title: 'Фон чата',
          initiallyExpanded: false,
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: ChatWallpaperCatalog.all.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemBuilder: (context, index) {
              final item = ChatWallpaperCatalog.all[index];
              final selected = item.id == wallpaperId;
              return InkWell(
                onTap: () => onWallpaperChanged(item.id),
                borderRadius: BorderRadius.circular(14),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ChatWallpaperBackdrop(
                      wallpaperId: item.id,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FontSizeSlider extends StatelessWidget {
  const _FontSizeSlider({
    required this.fontScale,
    required this.onChanged,
  });

  final double? fontScale;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fontSize = AppearanceFontScaleController.fontSizeFromScale(fontScale);
    final min = AppearanceFontScaleController.minFontSize.toDouble();
    final max = AppearanceFontScaleController.maxFontSize.toDouble();

    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.outlineVariant.withValues(alpha: 0.55),
              thumbColor: cs.primary,
              overlayColor: cs.primary.withValues(alpha: 0.12),
            ),
            child: Slider(
              min: min,
              max: max,
              divisions: (max - min).round(),
              value: fontSize.toDouble(),
              onChanged: (value) {
                onChanged(
                  AppearanceFontScaleController.scaleFromFontSize(
                    value.round(),
                  ),
                );
              },
            ),
          ),
        ),
        SizedBox(
          width: 28,
          child: Text(
            '$fontSize',
            textAlign: TextAlign.end,
            style: theme.textTheme.titleMedium?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class ThemeAppearancePreviewPanel extends StatelessWidget {
  const ThemeAppearancePreviewPanel({
    super.key,
    required this.seedColor,
    required this.fontScale,
    required this.wallpaperId,
    required this.applying,
    required this.onSave,
  });

  final Color seedColor;
  final double? fontScale;
  final String wallpaperId;
  final bool applying;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final draftScheme = ColorScheme.fromSeed(seedColor: seedColor);

    return Material(
      elevation: 6,
      color: Theme.of(context).colorScheme.surface,
      shadowColor: Colors.black26,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ThemePreview(
                seedColor: seedColor,
                fontScale: fontScale,
                wallpaperId: wallpaperId,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: applying ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: draftScheme.primary,
                  foregroundColor: draftScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: applying
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: draftScheme.onPrimary,
                        ),
                      )
                    : const Text('Сохранить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsBlock extends StatelessWidget {
  const _SettingsBlock({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _CollapsibleSettingsBlock extends StatefulWidget {
  const _CollapsibleSettingsBlock({
    required this.title,
    required this.child,
    this.subtitle,
    this.initiallyExpanded = false,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<_CollapsibleSettingsBlock> createState() =>
      _CollapsibleSettingsBlockState();
}

class _CollapsibleSettingsBlockState extends State<_CollapsibleSettingsBlock> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 12, 10, _expanded ? 10 : 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (!_expanded && widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: widget.child,
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
            sizeCurve: Curves.easeOutCubic,
          ),
        ],
      ),
    );
  }
}

class _HueGradientSlider extends StatelessWidget {
  const _HueGradientSlider({
    required this.hue,
    required this.onChanged,
  });

  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final markerX = (hue / 360) * width;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) => _updateHue(event.localPosition.dx, width),
          onPointerMove: (event) => _updateHue(event.localPosition.dx, width),
          child: SizedBox(
            height: 56,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFFF0000),
                        Color(0xFFFFFF00),
                        Color(0xFF00FF00),
                        Color(0xFF00FFFF),
                        Color(0xFF0000FF),
                        Color(0xFFFF00FF),
                        Color(0xFFFF0000),
                      ],
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black12,
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: (markerX - 16).clamp(0, width - 32),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.seedColorFromHue(hue),
                      border: Border.all(color: Colors.white, width: 3.5),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _updateHue(double x, double width) {
    if (width <= 0) return;
    final clamped = x.clamp(0, width);
    onChanged((clamped / width) * 360);
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({
    required this.seedColor,
    required this.fontScale,
    required this.wallpaperId,
  });

  final Color seedColor;
  final double? fontScale;
  final String wallpaperId;

  @override
  Widget build(BuildContext context) {
    final previewTheme = AppTheme.lightTheme(seedColor);
    final media = MediaQuery.of(context);
    final scaled = fontScale == null
        ? media
        : media.copyWith(textScaler: TextScaler.linear(fontScale!));

    return MediaQuery(
      data: scaled,
      child: Theme(
        data: previewTheme,
        child: Builder(
          builder: (context) {
            final theme = Theme.of(context);
            final scheme = theme.colorScheme;

            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PreviewAppBar(scheme: scheme, theme: theme),
                    SizedBox(
                      height: 168,
                      child: ChatWallpaperBackdrop(
                        wallpaperId: wallpaperId,
                        child: _PreviewConversation(
                          scheme: scheme,
                          theme: theme,
                        ),
                      ),
                    ),
                    _PreviewBottomNav(scheme: scheme, theme: theme),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PreviewAppBar extends StatelessWidget {
  const _PreviewAppBar({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Family Space',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(Icons.search, color: scheme.onSurfaceVariant, size: 20),
          const SizedBox(width: 4),
          Icon(Icons.more_vert, color: scheme.onSurfaceVariant, size: 20),
        ],
      ),
    );
  }
}

class _PreviewConversation extends StatelessWidget {
  const _PreviewConversation({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 210),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                  bottomLeft: Radius.circular(4),
                ),
              ),
              child: Text(
                'Привет! Как дела?',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 210),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Text(
                'Отлично, скоро буду!',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ),
          const Spacer(),
          DecoratedBox(
            decoration: FamilyInputStyles.composeShellDecoration(theme),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Сообщение...',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(Icons.send_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBottomNav extends StatelessWidget {
  const _PreviewBottomNav({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _PreviewNavItem(
            icon: Icons.chat,
            label: 'Чат',
            scheme: scheme,
            theme: theme,
            selected: true,
          ),
          _PreviewNavItem(
            icon: Icons.dynamic_feed_outlined,
            label: 'Лента',
            scheme: scheme,
            theme: theme,
          ),
          _PreviewNavItem(
            icon: Icons.people_outline,
            label: 'Семья',
            scheme: scheme,
            theme: theme,
          ),
          _PreviewNavItem(
            icon: Icons.photo_library_outlined,
            label: 'Галерея',
            scheme: scheme,
            theme: theme,
          ),
          _PreviewNavItem(
            icon: Icons.calendar_month_outlined,
            label: 'Календарь',
            scheme: scheme,
            theme: theme,
          ),
        ],
      ),
    );
  }
}

class _PreviewNavItem extends StatelessWidget {
  const _PreviewNavItem({
    required this.icon,
    required this.label,
    required this.scheme,
    required this.theme,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final ColorScheme scheme;
  final ThemeData theme;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 9,
          ),
        ),
      ],
    );
  }
}
