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
      retinaMode: !kIsWeb && MediaQuery.devicePixelRatioOf(context) > 1.5,
      maxNativeZoom: 19,
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
