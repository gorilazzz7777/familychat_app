enum MediaCacheStaleOption {
  sevenDays,
  thirtyDays,
  ninetyDays,
  forever,
}

enum MediaCacheSizeOption {
  mb500,
  gb1,
  gb2,
  gb5,
  gb10,
}

extension MediaCacheStaleOptionX on MediaCacheStaleOption {
  String get storageKey => switch (this) {
        MediaCacheStaleOption.sevenDays => '7d',
        MediaCacheStaleOption.thirtyDays => '30d',
        MediaCacheStaleOption.ninetyDays => '90d',
        MediaCacheStaleOption.forever => 'forever',
      };

  String get label => switch (this) {
        MediaCacheStaleOption.sevenDays => '7 дней',
        MediaCacheStaleOption.thirtyDays => '30 дней',
        MediaCacheStaleOption.ninetyDays => '90 дней',
        MediaCacheStaleOption.forever => 'Без срока',
      };

  /// `null` — не вытесняем по возрасту.
  Duration? get duration => switch (this) {
        MediaCacheStaleOption.sevenDays => const Duration(days: 7),
        MediaCacheStaleOption.thirtyDays => const Duration(days: 30),
        MediaCacheStaleOption.ninetyDays => const Duration(days: 90),
        MediaCacheStaleOption.forever => null,
      };

  static MediaCacheStaleOption fromStorage(Object? raw) {
    final key = raw?.toString().trim() ?? '';
    for (final option in MediaCacheStaleOption.values) {
      if (option.storageKey == key) return option;
    }
    return MediaCacheStaleOption.thirtyDays;
  }
}

extension MediaCacheSizeOptionX on MediaCacheSizeOption {
  String get storageKey => switch (this) {
        MediaCacheSizeOption.mb500 => '512mb',
        MediaCacheSizeOption.gb1 => '1gb',
        MediaCacheSizeOption.gb2 => '2gb',
        MediaCacheSizeOption.gb5 => '5gb',
        MediaCacheSizeOption.gb10 => '10gb',
      };

  String get label => switch (this) {
        MediaCacheSizeOption.mb500 => '500 МБ',
        MediaCacheSizeOption.gb1 => '1 ГБ',
        MediaCacheSizeOption.gb2 => '2 ГБ',
        MediaCacheSizeOption.gb5 => '5 ГБ',
        MediaCacheSizeOption.gb10 => '10 ГБ',
      };

  int get bytes => switch (this) {
        MediaCacheSizeOption.mb500 => 500 * 1024 * 1024,
        MediaCacheSizeOption.gb1 => 1024 * 1024 * 1024,
        MediaCacheSizeOption.gb2 => 2 * 1024 * 1024 * 1024,
        MediaCacheSizeOption.gb5 => 5 * 1024 * 1024 * 1024,
        MediaCacheSizeOption.gb10 => 10 * 1024 * 1024 * 1024,
      };

  static MediaCacheSizeOption fromStorage(Object? raw) {
    final key = raw?.toString().trim() ?? '';
    for (final option in MediaCacheSizeOption.values) {
      if (option.storageKey == key) return option;
    }
    return MediaCacheSizeOption.gb2;
  }
}
