import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/settings/shell_nav_layout.dart';

class ShellNavBar extends StatelessWidget {
  const ShellNavBar({
    super.key,
    required this.layout,
    required this.selectedIndex,
    required this.chatUnread,
    required this.chatBadgeLabel,
    required this.onDestinationSelected,
    required this.onBarReorder,
  });

  final ShellNavLayout layout;
  final int selectedIndex;
  final int chatUnread;
  final String chatBadgeLabel;
  final ValueChanged<int> onDestinationSelected;
  final void Function(int oldIndex, int newIndex) onBarReorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final navTheme = NavigationBarTheme.of(context);
    final background = navTheme.backgroundColor ??
        theme.colorScheme.surfaceContainer;
    final height = navTheme.height ?? 80;
    final sections = layout.barSections;
    final showMore = layout.showMore;
    final slotCount = sections.length + (showMore ? 1 : 0);
    if (slotCount == 0) return const SizedBox.shrink();

    return Material(
      color: background,
      elevation: navTheme.elevation ?? 0,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slotWidth = constraints.maxWidth / slotCount;
              return Row(
                children: [
                  SizedBox(
                    width: slotWidth * sections.length,
                    child: ReorderableListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.zero,
                      clipBehavior: Clip.none,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      proxyDecorator: _proxyDecorator,
                      onReorderStart: (_) {
                        HapticFeedback.mediumImpact();
                      },
                      onReorder: onBarReorder,
                      itemCount: sections.length,
                      itemBuilder: (context, index) {
                        final section = sections[index];
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(section),
                          index: index,
                          child: SizedBox(
                            width: slotWidth,
                            child: _ShellNavButton(
                              icon: ShellNavLayout.icon(section),
                              selectedIcon:
                                  ShellNavLayout.icon(section, selected: true),
                              label: ShellNavLayout.label(section),
                              selected: selectedIndex == index,
                              badgeLabel: section == ShellSection.chat &&
                                      chatUnread > 0
                                  ? chatBadgeLabel
                                  : null,
                              onTap: () => onDestinationSelected(index),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (showMore)
                    SizedBox(
                      width: slotWidth,
                      child: _ShellNavButton(
                        icon: Icons.more_horiz,
                        selectedIcon: Icons.more_horiz,
                        label: 'Ещё',
                        selected: selectedIndex == sections.length,
                        onTap: () => onDestinationSelected(sections.length),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static Widget _proxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeOut.transform(animation.value);
        return Transform.scale(
          scale: 1 + (0.08 * t),
          child: Material(
            elevation: 8 * t,
            color: Colors.transparent,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(16),
            child: child,
          ),
        );
      },
    );
  }
}

class _ShellNavButton extends StatelessWidget {
  const _ShellNavButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeLabel,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final navTheme = NavigationBarTheme.of(context);
    final indicatorColor =
        navTheme.indicatorColor ?? scheme.secondaryContainer;
    Widget iconWidget = Icon(
      selected ? selectedIcon : icon,
      color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
    );
    if (badgeLabel != null) {
      iconWidget = Badge(
        label: Text(badgeLabel!),
        child: iconWidget,
      );
    }

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              decoration: ShapeDecoration(
                color: selected ? indicatorColor : Colors.transparent,
                shape: navTheme.indicatorShape ?? const StadiumBorder(),
              ),
              child: iconWidget,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
