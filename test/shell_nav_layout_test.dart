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

  test('custom menu order is applied to the bar', () {
    final layout = ShellNavLayout.fromSettings(
      const FamilyChatAppSettings(
        menuOrder: ['gallery', 'chat', 'calendar', 'feed', 'family'],
      ),
    );
    expect(layout.barSections, [
      ShellSection.gallery,
      ShellSection.chat,
      ShellSection.calendar,
      ShellSection.feed,
      ShellSection.family,
    ]);
  });

  test('hidden sections are skipped in the bar', () {
    final layout = ShellNavLayout.fromSettings(
      const FamilyChatAppSettings(
        menuFamily: false,
        menuOrder: ['gallery', 'chat', 'family', 'feed', 'calendar'],
      ),
    );
    expect(layout.barSections, [
      ShellSection.gallery,
      ShellSection.chat,
      ShellSection.feed,
      ShellSection.calendar,
    ]);
  });

  test('orderKeysAfterMove puts a bar item first', () {
    final keys = ShellNavLayout.orderKeysAfterMove(
      currentKeys: FamilyChatAppSettings.defaultMenuOrder,
      enabled: [
        ShellSection.chat,
        ShellSection.feed,
        ShellSection.family,
        ShellSection.gallery,
        ShellSection.calendar,
      ],
      oldIndex: 4,
      newIndex: 0,
    );
    expect(keys.first, 'calendar');
    expect(keys, [
      'calendar',
      'chat',
      'feed',
      'family',
      'gallery',
    ]);
  });
}
