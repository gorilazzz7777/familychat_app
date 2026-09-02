import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Временная точка на семейной карте (individual premium).
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

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'expires_at_ms': expiresAtMs,
      };

  factory MapDisplayOverride.fromJson(Map<String, dynamic> json) {
    return MapDisplayOverride(
      latitude: (json['latitude'] as num?)?.toDouble() ??
          double.tryParse('${json['latitude']}') ??
          0,
      longitude: (json['longitude'] as num?)?.toDouble() ??
          double.tryParse('${json['longitude']}') ??
          0,
      expiresAtMs: int.tryParse(json['expires_at_ms']?.toString() ?? '') ?? 0,
    );
  }
}

abstract final class MapDisplayOverrideStore {
  MapDisplayOverrideStore._();

  static const _prefsKey = 'familychat_map_display_override_v1';

  static Future<MapDisplayOverride?> read() async {
    if (kIsWeb) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final override = MapDisplayOverride.fromJson(json);
      if (!override.isActive) {
        await clear();
        return null;
      }
      return override;
    } catch (_) {
      return null;
    }
  }

  static Future<void> set({
    required double latitude,
    required double longitude,
    required Duration duration,
  }) async {
    if (kIsWeb) return;
    final expiresAtMs =
        DateTime.now().add(duration).millisecondsSinceEpoch;
    final override = MapDisplayOverride(
      latitude: latitude,
      longitude: longitude,
      expiresAtMs: expiresAtMs,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(override.toJson()));
  }

  static Future<void> clear() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
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
