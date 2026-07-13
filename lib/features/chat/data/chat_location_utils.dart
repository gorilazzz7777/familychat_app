import 'package:url_launcher/url_launcher.dart';

class ChatLocationPoint {
  const ChatLocationPoint({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
      };

  static ChatLocationPoint? fromDynamic(dynamic raw) {
    if (raw is! Map) return null;
    final lat = _asDouble(raw['latitude']);
    final lng = _asDouble(raw['longitude']);
    if (lat == null || lng == null) return null;
    return ChatLocationPoint(latitude: lat, longitude: lng);
  }

  static ChatLocationPoint? fromMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null) return null;
    return fromDynamic(metadata['location']);
  }

  static double? _asDouble(Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return double.tryParse('$value');
  }
}

Future<void> openChatLocationInYandexMaps(ChatLocationPoint point) async {
  final pt = '${point.longitude},${point.latitude}';
  final appUri = Uri.parse('yandexmaps://maps.yandex.ru/?pt=$pt&z=16&l=map');
  final webUri = Uri.parse('https://yandex.ru/maps/?pt=$pt&z=16&l=map');

  if (await canLaunchUrl(appUri)) {
    final launched = await launchUrl(appUri, mode: LaunchMode.externalApplication);
    if (launched) return;
  }
  await launchUrl(webUri, mode: LaunchMode.externalApplication);
}
