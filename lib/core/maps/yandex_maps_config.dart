/// Конфиг Яндекс.Карт.
///
/// MapKit SDK-ключ (`apiKey`) — для нативного MapKit (AndroidManifest).
/// Raster Tiles API (`tiles.api-maps.yandex.ru`) этот ключ отклоняет (403),
/// поэтому в UI используем публичный renderer Яндекса.
abstract final class YandexMapsConfig {
  static const String apiKey = String.fromEnvironment(
    'YANDEX_MAPS_API_KEY',
    defaultValue: '0dc3b06e-efcb-42e6-af03-f727adca58bf',
  );

  /// Тайлы Яндекса (Web Mercator XYZ), совместимо с flutter_map.
  static String tileUrlTemplate({required String apiKey}) =>
      'https://core-renderer-tiles.maps.yandex.net/tiles'
      '?l=map&x={x}&y={y}&z={z}&scale=1&lang=ru_RU';
}
