import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../data/chat_location_utils.dart';

/// Миникарта с текущей позицией и точкой отправки.
///
/// Тайлы Carto (не raw OSM): на web OSM часто блокирует запросы без
/// User-Agent, который браузер не даёт задать — карта остаётся серой.
class ChatLocationMap extends StatelessWidget {
  const ChatLocationMap({
    super.key,
    required this.sendPoint,
    this.userPoint,
    this.height = 220,
    this.interactive = true,
    this.onSendPointChanged,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final ChatLocationPoint sendPoint;
  final ChatLocationPoint? userPoint;
  final double height;
  final bool interactive;
  final ValueChanged<ChatLocationPoint>? onSendPointChanged;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final send = LatLng(sendPoint.latitude, sendPoint.longitude);
    final markers = <Marker>[
      if (userPoint != null)
        Marker(
          point: LatLng(userPoint!.latitude, userPoint!.longitude),
          width: 18,
          height: 18,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      Marker(
        point: send,
        width: 36,
        height: 36,
        child: const Icon(Icons.location_on, color: Colors.red, size: 36),
      ),
    ];

    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: send,
            initialZoom: 15,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            interactionOptions: InteractionOptions(
              flags: interactive
                  ? (InteractiveFlag.all & ~InteractiveFlag.flingAnimation)
                  : InteractiveFlag.none,
            ),
            onTap: interactive && onSendPointChanged != null
                ? (_, latLng) => onSendPointChanged!(
                      ChatLocationPoint(
                        latitude: latLng.latitude,
                        longitude: latLng.longitude,
                      ),
                    )
                : null,
          ),
          children: [
            TileLayer(
              // CartoCDN: CORS + браузерный доступ; OSM tile.openstreetmap.org на web часто пустой.
              urlTemplate:
                  'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'com.familychat.familychat_app',
              retinaMode: !kIsWeb && MediaQuery.devicePixelRatioOf(context) > 1.5,
              maxNativeZoom: 19,
              errorTileCallback: (tile, error, stackTrace) {
                if (kDebugMode) {
                  debugPrint('map tile error: $error');
                }
              },
            ),
            MarkerLayer(markers: markers),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution(
                  'OpenStreetMap',
                  prependCopyright: true,
                ),
                TextSourceAttribution('CARTO'),
              ],
              alignment: AttributionAlignment.bottomLeft,
              showFlutterMapAttribution: false,
            ),
          ],
        ),
      ),
    );
  }
}
