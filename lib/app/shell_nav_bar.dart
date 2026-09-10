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

  /// Approximate content height of the pill (without SafeArea / outer padding).
  static const double pillHeight = 56;
  static const EdgeInsets outerPadding = EdgeInsets.fromLTRB(14, 0, 14, 10);

  /// Extra scroll inset so last list items can sit above the floating pill.
  static double contentBottomInset(BuildContext context) {
    return pillHeight +
        outerPadding.bottom +
        MediaQuery.paddingOf(context).bottom +
        8;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sections = layout.barSections;
    final showMore = layout.showMore;
    final slotCount = sections.length + (showMore ? 1 : 0);
    if (slotCount == 0) return const SizedBox.shrink();

    // Чуть темнее surface, чтобы на белом фоне не сливалась.
    final background = Color.alphaBlend(
      scheme.onSurface.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.16 : 0.09,
      ),
      scheme.surface,
    );

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: outerPadding,
          child: Material(
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
              height: pillHeight,
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
                                  selectedIcon: ShellNavLayout.icon(
                                    section,
                                    selected: true,
                                  ),
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
                            onTap: () =>
                                onDestinationSelected(sections.length),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
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
    final foreground =
        selected ? scheme.primary : scheme.onSurfaceVariant;
    Widget iconWidget = Icon(
      selected ? selectedIcon : icon,
      color: foreground,
      size: 21,
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

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
                  decoration: ShapeDecoration(
                    color: selected ? indicatorColor : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Column(
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
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
