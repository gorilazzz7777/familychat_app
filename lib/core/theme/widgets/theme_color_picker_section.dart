import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Горизонтальная линия оттенков + превью и кнопка применения.
class ThemeColorPickerSection extends StatefulWidget {
  const ThemeColorPickerSection({
    super.key,
    required this.currentSeedColor,
    required this.onApply,
  });

  final Color currentSeedColor;
  final Future<void> Function(Color seedColor) onApply;

  @override
  State<ThemeColorPickerSection> createState() => _ThemeColorPickerSectionState();
}

class _ThemeColorPickerSectionState extends State<ThemeColorPickerSection> {
  late double _hue;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _hue = AppTheme.hueFromSeedColor(widget.currentSeedColor);
  }

  @override
  void didUpdateWidget(covariant ThemeColorPickerSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentSeedColor != widget.currentSeedColor && !_applying) {
      _hue = AppTheme.hueFromSeedColor(widget.currentSeedColor);
    }
  }

  Color get _draftSeed => AppTheme.seedColorFromHue(_hue);

  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      await widget.onApply(_draftSeed);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Цвет темы сохранён')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить цвет: $e')),
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draftSeed = _draftSeed;
    final draftScheme = ColorScheme.fromSeed(seedColor: draftSeed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Оформление',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Выберите основной цвет — остальные оттенки подстроятся автоматически.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _HueGradientSlider(
          hue: _hue,
          onChanged: (value) => setState(() => _hue = value),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: draftSeed,
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              AppTheme.colorToHex(draftSeed),
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _ThemePreview(seedColor: draftSeed),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _applying ? null : _apply,
          style: FilledButton.styleFrom(
            backgroundColor: draftScheme.primary,
            foregroundColor: draftScheme.onPrimary,
          ),
          child: _applying
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: draftScheme.onPrimary,
                  ),
                )
              : const Text('Применить цвет'),
        ),
      ],
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

        return GestureDetector(
          onPanDown: (d) => _updateHue(d.localPosition.dx, width),
          onPanUpdate: (d) => _updateHue(d.localPosition.dx, width),
          onTapDown: (d) => _updateHue(d.localPosition.dx, width),
          child: SizedBox(
            height: 40,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 16,
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
                  ),
                ),
                Positioned(
                  left: (markerX - 12).clamp(0, width - 24),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.seedColorFromHue(hue),
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 1),
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
  const _ThemePreview({required this.seedColor});

  final Color seedColor;

  @override
  Widget build(BuildContext context) {
    final previewTheme = AppTheme.lightTheme(seedColor);

    return Theme(
      data: previewTheme,
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;

          return Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Превью',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.family_restroom, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Family Chat',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Icon(Icons.notifications_none, color: scheme.primary),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: () {},
                    child: const Text('Кнопка'),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Пример сообщения в чате',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
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
