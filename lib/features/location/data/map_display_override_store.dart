import '../../familychat/data/familychat_repository.dart';

/// Временная точка на семейной карте (individual premium), хранится на сервере.
class MapDisplayOverride {
  const MapDisplayOverride({
    required this.latitude,
    required this.longitude,
    required this.expiresAtMs,
  });

  final double latitude;
  final double longitude;
  final int expiresAtMs;

  bool get isActive => DateTime.now().millisecondsSinceEpoch < expiresAtMs;

  Duration? get remaining {
    if (!isActive) return null;
    final ms = expiresAtMs - DateTime.now().millisecondsSinceEpoch;
    if (ms <= 0) return null;
    return Duration(milliseconds: ms);
  }

  factory MapDisplayOverride.fromServerJson(Map<String, dynamic> json) {
    var expiresAtMs = int.tryParse(json['expires_at_ms']?.toString() ?? '') ?? 0;
    if (expiresAtMs <= 0) {
      final raw = json['expires_at']?.toString();
      if (raw != null && raw.isNotEmpty) {
        final parsed = DateTime.tryParse(raw);
        if (parsed != null) {
          expiresAtMs = parsed.toLocal().millisecondsSinceEpoch;
        }
      }
    }
    return MapDisplayOverride(
      latitude: (json['latitude'] as num?)?.toDouble() ??
          double.tryParse('${json['latitude']}') ??
          0,
      longitude: (json['longitude'] as num?)?.toDouble() ??
          double.tryParse('${json['longitude']}') ??
          0,
      expiresAtMs: expiresAtMs,
    );
  }
}

abstract final class MapDisplayOverrideStore {
  MapDisplayOverrideStore._();

  static MapDisplayOverride? _parsePayload(Map<String, dynamic>? data) {
    if (data == null) return null;
    final raw = data['display_override'];
    if (raw is! Map) return null;
    final override =
        MapDisplayOverride.fromServerJson(Map<String, dynamic>.from(raw));
    if (!override.isActive) return null;
    return override;
  }

  static Future<MapDisplayOverride?> read(FamilyChatRepository repo) async {
    try {
      final data = await repo.getLocationDisplayOverride();
      return _parsePayload(data);
    } catch (_) {
      return null;
    }
  }

  static Future<MapDisplayOverride?> set({
    required FamilyChatRepository repo,
    required double latitude,
    required double longitude,
    required Duration duration,
  }) async {
    final data = await repo.setLocationDisplayOverride(
      latitude: latitude,
      longitude: longitude,
      durationMinutes: duration.inMinutes,
    );
    return _parsePayload(data);
  }

  static Future<void> clear(FamilyChatRepository repo) async {
    await repo.clearLocationDisplayOverride();
  }
}

/// Пресеты длительности показа на карте.
enum MapDisplayDurationPreset {
  minutes30('30 мин', Duration(minutes: 30)),
  hour1('1 ч', Duration(hours: 1)),
  hours2('2 ч', Duration(hours: 2)),
  hours4('4 ч', Duration(hours: 4)),
  hours8('8 ч', Duration(hours: 8)),
  day1('24 ч', Duration(hours: 24));

  const MapDisplayDurationPreset(this.label, this.duration);

  final String label;
  final Duration duration;
}

String formatMapDisplayRemaining(Duration d) {
  if (d.inDays >= 1) {
    final h = d.inHours.remainder(24);
    return h > 0 ? '${d.inDays} д ${h} ч' : '${d.inDays} д';
  }
  if (d.inHours >= 1) {
    final m = d.inMinutes.remainder(60);
    return m > 0 ? '${d.inHours} ч ${m} мин' : '${d.inHours} ч';
  }
  if (d.inMinutes >= 1) return '${d.inMinutes} мин';
  return 'меньше минуты';
}
