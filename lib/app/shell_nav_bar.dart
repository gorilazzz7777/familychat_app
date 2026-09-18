import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../core/settings/shell_nav_layout.dart';

class ShellNavBar extends StatelessWidget {
  const ShellNavBar({
    super.key,
    required this.layout,
    required this.selectedIndex,
    required this.chatUnread,
    required this.chatBadgeLabel,
    required this.onDestinationSelected,
    required this.onConfigureMenu,
    this.showLabels = false,
  });

  final ShellNavLayout layout;
  final int selectedIndex;
  final int chatUnread;
  final String chatBadgeLabel;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onConfigureMenu;
  final bool showLabels;

  static const double pillHeightLabeled = 56;
  static const double pillHeightIconsOnly = 52;
  static const double slotWidthLabeled = 64;
  static const double slotWidthIconsOnly = 52;
  static const EdgeInsets outerPadding = EdgeInsets.fromLTRB(14, 0, 14, 10);

  static double pillHeightFor({required bool showLabels}) =>
      showLabels ? pillHeightLabeled : pillHeightIconsOnly;

  static double slotWidthFor({required bool showLabels}) =>
      showLabels ? slotWidthLabeled : slotWidthIconsOnly;

  /// Approximate content height of the pill (without SafeArea / outer padding).
  static double pillHeight = pillHeightIconsOnly;

  /// Extra scroll inset so last list items can sit above the floating pill.
  static double contentBottomInset(
    BuildContext context, {
    bool showLabels = false,
  }) {
    return pillHeightFor(showLabels: showLabels) +
        outerPadding.bottom +
        MediaQuery.paddingOf(context).bottom +
        8;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sections = layout.barSections;
    final showMore = layout.showMore;
    final slotCount = sections.length + (showMore ? 1 : 0);
    if (slotCount == 0) return const SizedBox.shrink();

    final height = pillHeightFor(showLabels: showLabels);
    final slotWidth = slotWidthFor(showLabels: showLabels);
    final barWidth = showLabels
        ? null // stretch when labels need room
        : slotWidth * slotCount;

    final background = Color.alphaBlend(
      scheme.onSurface.withValues(
        alpha: Theme.of(context).brightness == Brightness.dark ? 0.16 : 0.09,
      ),
      scheme.surface,
    );

    Widget buildButton({
      required IconData icon,
      required IconData selectedIcon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
      String? badgeLabel,
    }) {
      return _ShellNavButton(
        icon: icon,
        selectedIcon: selectedIcon,
        label: label,
        selected: selected,
        showLabel: showLabels,
        badgeLabel: badgeLabel,
        onTap: onTap,
        onLongPress: () => _showConfigureMenuSheet(context),
      );
    }

    final buttons = <Widget>[
      for (var index = 0; index < sections.length; index++)
        Expanded(
          child: buildButton(
            icon: ShellNavLayout.icon(sections[index]),
            selectedIcon: ShellNavLayout.icon(sections[index], selected: true),
            label: ShellNavLayout.label(sections[index]),
            selected: selectedIndex == index,
            badgeLabel: sections[index] == ShellSection.chat && chatUnread > 0
                ? chatBadgeLabel
                : null,
            onTap: () => onDestinationSelected(index),
          ),
        ),
      if (showMore)
        Expanded(
          child: buildButton(
            icon: ShellNavLayout.moreIcon,
            selectedIcon: ShellNavLayout.moreIcon,
            label: 'Ещё',
            selected: selectedIndex == sections.length,
            onTap: () => onDestinationSelected(sections.length),
          ),
        ),
    ];

    final iconsOnlyButtons = <Widget>[
      for (var index = 0; index < sections.length; index++)
        SizedBox(
          width: slotWidth,
          child: buildButton(
            icon: ShellNavLayout.icon(sections[index]),
            selectedIcon: ShellNavLayout.icon(sections[index], selected: true),
            label: ShellNavLayout.label(sections[index]),
            selected: selectedIndex == index,
            badgeLabel: sections[index] == ShellSection.chat && chatUnread > 0
                ? chatBadgeLabel
                : null,
            onTap: () => onDestinationSelected(index),
          ),
        ),
      if (showMore)
        SizedBox(
          width: slotWidth,
          child: buildButton(
            icon: ShellNavLayout.moreIcon,
            selectedIcon: ShellNavLayout.moreIcon,
            label: 'Ещё',
            selected: selectedIndex == sections.length,
            onTap: () => onDestinationSelected(sections.length),
          ),
        ),
    ];

    final pill = Material(
      color: background,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      shape: StadiumBorder(
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: height,
        width: barWidth,
        child: Row(
          children: showLabels ? buttons : iconsOnlyButtons,
        ),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: outerPadding,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (showLabels) Expanded(child: pill) else pill,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showConfigureMenuSheet(BuildContext context) async {
    final go = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.settings_2),
                title: const Text('Настроить меню'),
                subtitle: const Text('Порядок, разделы и подписи'),
                onTap: () => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (go == true) onConfigureMenu();
  }
}

class _ShellNavButton extends StatelessWidget {
  const _ShellNavButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.showLabel,
    required this.onTap,
    required this.onLongPress,
    this.badgeLabel,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Brighter than secondaryContainer — clear primary wash.
    final indicatorColor = Color.alphaBlend(
      scheme.primary.withValues(alpha: theme.brightness == Brightness.dark ? 0.38 : 0.28),
      scheme.surface,
    );
    final foreground =
        selected ? scheme.primary : scheme.onSurfaceVariant;
    Widget iconWidget = Icon(
      selected ? selectedIcon : icon,
      color: foreground,
      size: showLabel ? 22 : 26,
    );
    if (badgeLabel != null) {
      iconWidget = Badge(
        label: Text(
          badgeLabel!,
          style: const TextStyle(fontSize: 10),
        ),
        child: iconWidget,
      );
    }

    final content = showLabel
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              iconWidget,
              const SizedBox(height: 1),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontSize: 10.5,
                    height: 1.1,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          )
        : iconWidget;

    final ShapeBorder shape = showLabel
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))
        : const CircleBorder();

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            padding: showLabel
                ? const EdgeInsets.fromLTRB(8, 5, 8, 5)
                : EdgeInsets.zero,
            width: showLabel ? null : 42,
            height: showLabel ? null : 42,
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              color: selected ? indicatorColor : Colors.transparent,
              shape: shape,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}
