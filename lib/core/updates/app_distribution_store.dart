enum AppDistributionStore {
  play,
  rustore,
  appstore,
  unknown;

  String get label => switch (this) {
        AppDistributionStore.play => 'Google Play',
        AppDistributionStore.rustore => 'RuStore',
        AppDistributionStore.appstore => 'App Store',
        AppDistributionStore.unknown => 'магазин',
      };
}
