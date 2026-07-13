import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../../widgets/family_input_styles.dart';

/// Горизонтальная линия оттенков + превью и кнопка применения.
class ThemeColorPickerBody extends StatefulWidget {
  const ThemeColorPickerBody({
    super.key,
    required this.currentSeedColor,
    required this.onApply,
  });

  final Color currentSeedColor;
  final Future<void> Function(Color seedColor) onApply;

  @override
  State<ThemeColorPickerBody> createState() => _ThemeColorPickerBodyState();
}

class _ThemeColorPickerBodyState extends State<ThemeColorPickerBody> {
  late double _hue;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _hue = AppTheme.hueFromSeedColor(widget.currentSeedColor);
  }

  @override
  void didUpdateWidget(covariant ThemeColorPickerBody oldWidget) {
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Выберите основной цвет — остальные оттенки подстроятся автоматически.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Оттенок',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        _HueGradientSlider(
          hue: _hue,
          onChanged: (value) => setState(() => _hue = value),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: draftSeed,
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: draftSeed.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              AppTheme.colorToHex(draftSeed),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Как будет выглядеть приложение',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        _ThemePreview(seedColor: draftSeed),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _applying ? null : _apply,
          style: FilledButton.styleFrom(
            backgroundColor: draftScheme.primary,
            foregroundColor: draftScheme.onPrimary,
            padding: const EdgeInsets.symmetric(vertical: 14),
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

          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ColoredBox(
                color: scheme.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PreviewAppBar(scheme: scheme, theme: theme),
                    _PreviewChatList(scheme: scheme, theme: theme),
                    _PreviewConversation(scheme: scheme, theme: theme),
                    _PreviewControls(scheme: scheme, theme: theme),
                    _PreviewBottomNav(scheme: scheme, theme: theme),
                  ],
                ),
              ),
            ),
          );
        },
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
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Семейный чат',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(Icons.search, color: scheme.onSurfaceVariant, size: 22),
          const SizedBox(width: 4),
          Icon(Icons.more_vert, color: scheme.onSurfaceVariant, size: 22),
        ],
      ),
    );
  }
}

class _PreviewChatList extends StatelessWidget {
  const _PreviewChatList({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: Column(
        children: [
          _PreviewChatRow(
            scheme: scheme,
            theme: theme,
            title: 'Семейная группа',
            subtitle: 'Мама: Доброе утро!',
            time: '09:41',
            unread: 2,
            selected: true,
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          _PreviewChatRow(
            scheme: scheme,
            theme: theme,
            title: 'Папа',
            subtitle: 'Фото с праздника',
            time: 'Вчера',
            hasPhoto: true,
          ),
        ],
      ),
    );
  }
}

class _PreviewChatRow extends StatelessWidget {
  const _PreviewChatRow({
    required this.scheme,
    required this.theme,
    required this.title,
    required this.subtitle,
    required this.time,
    this.unread = 0,
    this.selected = false,
    this.hasPhoto = false,
  });

  final ColorScheme scheme;
  final ThemeData theme;
  final String title;
  final String subtitle;
  final String time;
  final int unread;
  final bool selected;
  final bool hasPhoto;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: scheme.primaryContainer,
            child: Icon(Icons.group, color: scheme.onPrimaryContainer, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (hasPhoto) ...[
                      Icon(Icons.image_outlined, size: 14, color: scheme.primary),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                time,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: unread > 0 ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              if (unread > 0) ...[
                const SizedBox(height: 6),
                CircleAvatar(
                  radius: 10,
                  backgroundColor: scheme.primary,
                  child: Text(
                    '$unread',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
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
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 240),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
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
              constraints: const BoxConstraints(maxWidth: 240),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: FamilyInputStyles.composeShellDecoration(theme),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    enabled: false,
                    decoration: const InputDecoration(
                      hintText: 'Сообщение...',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.fromLTRB(16, 10, 0, 10),
                      isDense: true,
                    ),
                  ),
                ),
                Icon(Icons.send_rounded, color: scheme.primary),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewControls extends StatelessWidget {
  const _PreviewControls({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: () {},
              child: const Text('Сохранить'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              onPressed: () {},
              child: const Text('Отмена'),
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
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _PreviewNavItem(
            icon: Icons.home_outlined,
            label: 'Главная',
            scheme: scheme,
            theme: theme,
          ),
          _PreviewNavItem(
            icon: Icons.chat,
            label: 'Чат',
            scheme: scheme,
            theme: theme,
            selected: true,
            badge: '2',
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
            icon: Icons.more_horiz,
            label: 'Ещё',
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
    this.badge,
  });

  final IconData icon;
  final String label;
  final ColorScheme scheme;
  final ThemeData theme;
  final bool selected;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: 22, color: color),
            if (badge != null)
              Positioned(
                right: -8,
                top: -4,
                child: CircleAvatar(
                  radius: 8,
                  backgroundColor: scheme.primary,
                  child: Text(
                    badge!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimary,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}
