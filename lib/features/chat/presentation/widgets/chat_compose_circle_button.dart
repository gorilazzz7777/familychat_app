import 'package:flutter/material.dart';

/// Круглая кнопка внутри поля ввода чата.
class ChatComposeCircleButton extends StatelessWidget {
  const ChatComposeCircleButton({
    super.key,
    required this.icon,
    this.onTap,
    this.onLongPress,
    this.iconColor,
    this.backgroundColor,
    this.iconSize = 22,
    this.size = 40,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? iconColor;
  final Color? backgroundColor;
  final double iconSize;
  final double size;
  final String? tooltip;

  static Color defaultBackground(ColorScheme cs) => cs.surface;

  static Color defaultIconColor(ColorScheme cs) => cs.primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bg = backgroundColor ?? defaultBackground(cs);
    final fg = iconColor ?? defaultIconColor(cs);

    final child = SizedBox(
      width: size,
      height: size,
      child: Icon(icon, size: iconSize, color: fg),
    );

    final button = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        border: Border.all(
          color: cs.outline.withValues(alpha: 0.42),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: onTap == null && onLongPress == null
          ? child
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                customBorder: const CircleBorder(),
                child: child,
              ),
            ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: tooltip == null ? button : Tooltip(message: tooltip, child: button),
    );
  }
}
