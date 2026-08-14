enum ScreenTimeoutOption {
  system,
  oneMinute,
  twoMinutes,
  fiveMinutes,
  tenMinutes,
  thirtyMinutes,
  never,
}

extension ScreenTimeoutOptionX on ScreenTimeoutOption {
  String get storageKey => switch (this) {
        ScreenTimeoutOption.system => 'system',
        ScreenTimeoutOption.oneMinute => '1m',
        ScreenTimeoutOption.twoMinutes => '2m',
        ScreenTimeoutOption.fiveMinutes => '5m',
        ScreenTimeoutOption.tenMinutes => '10m',
        ScreenTimeoutOption.thirtyMinutes => '30m',
        ScreenTimeoutOption.never => 'never',
      };

  String get label => switch (this) {
        ScreenTimeoutOption.system => 'Системная',
        ScreenTimeoutOption.oneMinute => '1 минута',
        ScreenTimeoutOption.twoMinutes => '2 минуты',
        ScreenTimeoutOption.fiveMinutes => '5 минут',
        ScreenTimeoutOption.tenMinutes => '10 минут',
        ScreenTimeoutOption.thirtyMinutes => '30 минут',
        ScreenTimeoutOption.never => 'Никогда не выключать экран',
      };

  /// `null` — не держим экран (системный таймаут) или держим всегда.
  Duration? get idleDuration => switch (this) {
        ScreenTimeoutOption.system => null,
        ScreenTimeoutOption.oneMinute => const Duration(minutes: 1),
        ScreenTimeoutOption.twoMinutes => const Duration(minutes: 2),
        ScreenTimeoutOption.fiveMinutes => const Duration(minutes: 5),
        ScreenTimeoutOption.tenMinutes => const Duration(minutes: 10),
        ScreenTimeoutOption.thirtyMinutes => const Duration(minutes: 30),
        ScreenTimeoutOption.never => null,
      };

  bool get keepOnUntilIdle =>
      this != ScreenTimeoutOption.system && this != ScreenTimeoutOption.never;

  bool get keepOnAlways => this == ScreenTimeoutOption.never;

  static ScreenTimeoutOption fromStorage(Object? raw) {
    final key = raw?.toString().trim() ?? '';
    for (final option in ScreenTimeoutOption.values) {
      if (option.storageKey == key) return option;
    }
    return ScreenTimeoutOption.system;
  }
}
