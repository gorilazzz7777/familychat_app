/// Конфиг Яндекс.Карт (MapKit / Raster Tiles API).
///
/// В кабинете разработчика ограничьте ключ пакетом
/// `com.familychat.familychat_app` / доменом familychat-app.ru.
abstract final class YandexMapsConfig {
  static const String apiKey = String.fromEnvironment(
    'YANDEX_MAPS_API_KEY',
    defaultValue: '0dc3b06e-efcb-42e6-af03-f727adca58bf',
  );

  /// Web Mercator XYZ — совместимо с flutter_map.
  static String tileUrlTemplate({required String apiKey}) =>
      'https://tiles.api-maps.yandex.ru/v1/tiles/'
      '?apikey=$apiKey&lang=ru_RU&l=map&x={x}&y={y}&z={z}';
}
