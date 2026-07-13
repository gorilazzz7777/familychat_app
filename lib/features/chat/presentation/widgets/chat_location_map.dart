import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../data/chat_location_utils.dart';

/// Миникарта с текущей позицией и точкой отправки.
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
        height: height,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: send,
            initialZoom: 15,
            interactionOptions: InteractionOptions(
              flags: interactive ? InteractiveFlag.all : InteractiveFlag.none,
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
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.familychat.familychat_app',
            ),
            MarkerLayer(markers: markers),
          ],
        ),
      ),
    );
  }
}
