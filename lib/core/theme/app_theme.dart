import 'package:flutter/material.dart';

/// Цвета и сборка темы Family Chat из пользовательского seed.
class AppTheme {
  AppTheme._();

  static const defaultSeedColor = Color(0xFF2E7D32);

  static const _minSaturation = 0.42;
  static const _maxSaturation = 0.72;
  static const _minValue = 0.38;
  static const _maxValue = 0.52;
  static const _pickerSaturation = 0.58;
  static const _pickerValue = 0.47;

  static ThemeData lightTheme(Color seedColor) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: normalizeSeedColor(seedColor),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      tabBarTheme: const TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.tab,
        tabAlignment: TabAlignment.fill,
      ),
    );
  }

  static Color seedColorFromHue(double hue) {
    return HSVColor.fromAHSV(1, hue % 360, _pickerSaturation, _pickerValue).toColor();
  }

  static double hueFromSeedColor(Color color) {
    return HSVColor.fromColor(normalizeSeedColor(color)).hue;
  }

  static Color normalizeSeedColor(Color color) {
    final hsv = HSVColor.fromColor(color);
    final saturation = hsv.saturation.clamp(_minSaturation, _maxSaturation);
    final value = hsv.value.clamp(_minValue, _maxValue);
    return HSVColor.fromAHSV(1, hsv.hue, saturation, value).toColor();
  }

  static Color parseSeedColor(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return defaultSeedColor;
    if (!value.startsWith('#')) return defaultSeedColor;
    final hex = value.substring(1);
    if (hex.length != 6) return defaultSeedColor;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return defaultSeedColor;
    return normalizeSeedColor(Color(0xFF000000 | parsed));
  }

  static String colorToHex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}
