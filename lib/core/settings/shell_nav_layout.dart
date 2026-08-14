import 'app_settings.dart';

enum ShellSection { chat, feed, family, gallery, calendar }

class ShellNavLayout {
  const ShellNavLayout({
    required this.enabled,
    required this.barSections,
    required this.overflowSections,
    required this.showBar,
    required this.showMore,
  });

  static const maxBarSlots = 5;
  static const overflowKeepInBar = 4;

  final List<ShellSection> enabled;
  final List<ShellSection> barSections;
  final List<ShellSection> overflowSections;
  final bool showBar;
  final bool showMore;

  bool isEnabled(ShellSection section) => enabled.contains(section);

  factory ShellNavLayout.fromSettings(
    FamilyChatAppSettings settings, {
    List<ShellSection> extras = const [],
    Set<ShellSection> pinToBar = const {},
  }) {
    final enabled = <ShellSection>[
      ShellSection.chat,
      if (settings.menuFeed) ShellSection.feed,
      if (settings.menuFamily) ShellSection.family,
      if (settings.menuGallery) ShellSection.gallery,
      if (settings.menuCalendar) ShellSection.calendar,
      ...extras,
    ];
    if (enabled.length <= 1) {
      return ShellNavLayout(
        enabled: enabled,
        barSections: enabled,
        overflowSections: const [],
        showBar: false,
        showMore: false,
      );
    }
    if (enabled.length <= maxBarSlots) {
      return ShellNavLayout(
        enabled: enabled,
        barSections: enabled,
        overflowSections: const [],
        showBar: true,
        showMore: false,
      );
    }
    final overflow = <ShellSection>[];
    final bar = [...enabled];
    while (bar.length > overflowKeepInBar) {
      final idx = bar.lastIndexWhere((s) => !pinToBar.contains(s));
      if (idx < 0) break;
      overflow.insert(0, bar.removeAt(idx));
    }
    return ShellNavLayout(
      enabled: enabled,
      barSections: bar,
      overflowSections: overflow,
      showBar: true,
      showMore: overflow.isNotEmpty,
    );
  }

  static String label(ShellSection section) {
    return switch (section) {
      ShellSection.chat => 'Чат',
      ShellSection.feed => 'Лента',
      ShellSection.family => 'Семья',
      ShellSection.gallery => 'Галерея',
      ShellSection.calendar => 'Календарь',
    };
  }
}
