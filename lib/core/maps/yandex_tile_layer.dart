import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'yandex_maps_config.dart';

/// Слой тайлов Яндекс.Карт для flutter_map.
class YandexTileLayer extends StatelessWidget {
  const YandexTileLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final key = YandexMapsConfig.apiKey.trim();
    return TileLayer(
      urlTemplate: YandexMapsConfig.tileUrlTemplate(apiKey: key),
      userAgentPackageName: 'com.familychat.familychat_app',
      // retinaMode ломает первый paint с кастомным CRS / scale=1 у Яндекса.
      retinaMode: false,
      maxNativeZoom: 19,
      keepBuffer: 2,
      panBuffer: 1,
      errorTileCallback: (tile, error, stackTrace) {
        if (kDebugMode) {
          debugPrint('yandex tile error: $error');
        }
      },
    );
  }
}

class YandexMapAttribution extends StatelessWidget {
  const YandexMapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return const RichAttributionWidget(
      attributions: [
        TextSourceAttribution('Яндекс'),
      ],
      alignment: AttributionAlignment.bottomLeft,
      showFlutterMapAttribution: false,
    );
  }
}
