import 'package:flutter/material.dart';

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

  static const defaultOrder = [
    ShellSection.chat,
    ShellSection.feed,
    ShellSection.family,
    ShellSection.gallery,
    ShellSection.calendar,
  ];

  final List<ShellSection> enabled;
  final List<ShellSection> barSections;
  final List<ShellSection> overflowSections;
  final bool showBar;
  final bool showMore;

  bool isEnabled(ShellSection section) => enabled.contains(section);

  static ShellSection? parse(String? raw) {
    final key = raw?.trim() ?? '';
    for (final section in ShellSection.values) {
      if (section.name == key) return section;
    }
    return null;
  }

  static List<ShellSection> normalizedOrder(Iterable<String> keys) {
    final result = <ShellSection>[];
    final seen = <ShellSection>{};
    for (final key in keys) {
      final section = parse(key);
      if (section == null || !seen.add(section)) continue;
      result.add(section);
    }
    for (final section in defaultOrder) {
      if (seen.add(section)) result.add(section);
    }
    return result;
  }

  static bool isVisible(ShellSection section, FamilyChatAppSettings settings) {
    return switch (section) {
      ShellSection.chat => true,
      ShellSection.feed => settings.menuFeed,
      ShellSection.family => settings.menuFamily,
      ShellSection.gallery => settings.menuGallery,
      ShellSection.calendar => settings.menuCalendar,
    };
  }

  /// Сохраняемый порядок всех разделов после перестановки видимых.
  static List<String> orderKeysAfterMove({
    required List<String> currentKeys,
    required List<ShellSection> enabled,
    required int oldIndex,
    required int newIndex,
  }) {
    if (oldIndex < 0 || oldIndex >= enabled.length) return currentKeys;
    var to = newIndex;
    if (to > oldIndex) to -= 1;
    final nextEnabled = [...enabled];
    final item = nextEnabled.removeAt(oldIndex);
    nextEnabled.insert(to.clamp(0, nextEnabled.length), item);
    final visible = nextEnabled.toSet();
    final queue = [...nextEnabled];
    return [
      for (final section in normalizedOrder(currentKeys))
        if (visible.contains(section)) queue.removeAt(0).name else section.name,
    ];
  }

  factory ShellNavLayout.fromSettings(
    FamilyChatAppSettings settings, {
    List<ShellSection> extras = const [],
    Set<ShellSection> pinToBar = const {},
  }) {
    final enabled = <ShellSection>[
      for (final section in normalizedOrder(settings.menuOrder))
        if (isVisible(section, settings)) section,
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

  static IconData icon(ShellSection section, {bool selected = false}) {
    return switch (section) {
      ShellSection.chat =>
        selected ? Icons.chat : Icons.chat_outlined,
      ShellSection.feed =>
        selected ? Icons.dynamic_feed : Icons.dynamic_feed_outlined,
      ShellSection.family =>
        selected ? Icons.people : Icons.people_outline,
      ShellSection.gallery =>
        selected ? Icons.photo_library : Icons.photo_library_outlined,
      ShellSection.calendar =>
        selected ? Icons.calendar_month : Icons.calendar_month_outlined,
    };
  }
}
