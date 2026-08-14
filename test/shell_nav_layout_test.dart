import 'package:flutter_test/flutter_test.dart';

import 'package:familychat_app/core/settings/app_settings.dart';
import 'package:familychat_app/core/settings/shell_nav_layout.dart';

void main() {
  test('default settings show all five sections without overflow', () {
    final layout = ShellNavLayout.fromSettings(const FamilyChatAppSettings());
    expect(layout.showBar, isTrue);
    expect(layout.showMore, isFalse);
    expect(layout.barSections, [
      ShellSection.chat,
      ShellSection.feed,
      ShellSection.family,
      ShellSection.gallery,
      ShellSection.calendar,
    ]);
    expect(layout.overflowSections, isEmpty);
  });

  test('only chat hides the bar', () {
    final layout = ShellNavLayout.fromSettings(
      const FamilyChatAppSettings(
        menuFeed: false,
        menuFamily: false,
        menuGallery: false,
        menuCalendar: false,
      ),
    );
    expect(layout.showBar, isFalse);
    expect(layout.enabled, [ShellSection.chat]);
  });

  test('more than five items keeps four in the bar and overflow in More', () {
    final layout = ShellNavLayout.fromSettings(
      const FamilyChatAppSettings(),
      extras: [ShellSection.calendar],
    );
    expect(layout.showMore, isTrue);
    expect(layout.barSections.length, 4);
    expect(layout.overflowSections, isNotEmpty);
    expect(layout.barSections.first, ShellSection.chat);
  });

  test('pinned sections stay in the bar when overflowing', () {
    final layout = ShellNavLayout.fromSettings(
      const FamilyChatAppSettings(),
      extras: [ShellSection.calendar],
      pinToBar: {ShellSection.calendar},
    );
    expect(layout.barSections.contains(ShellSection.calendar), isTrue);
    expect(layout.overflowSections.contains(ShellSection.calendar), isFalse);
  });
}
