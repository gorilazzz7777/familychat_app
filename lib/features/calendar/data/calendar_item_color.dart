import 'package:flutter/material.dart';

/// Палитра для выбора цвета карточки в календаре.
const scheduleCardColorPresets = <String>[
  '#0F2E4D',
  '#FF8C42',
  '#66CC66',
  '#E55A5A',
  '#FFC107',
  '#26A69A',
  '#EF6C57',
  '#8E24AA',
  '#1E88E5',
  '#78909C',
];

const _defaultEvent = Color(0xFF5C6BC0);
const _defaultHoliday = Color(0xFF26A69A);
const _defaultBirthday = Color(0xFFFF8C42);

Color? parseCardColor(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty || !value.startsWith('#')) return null;
  final hex = value.substring(1);
  if (hex.length != 6) return null;
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  return Color(0xFF000000 | parsed);
}

String? colorToHex(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color scheduleItemBlockColor(Map<String, dynamic> item) {
  final custom = parseCardColor(item['card_color']?.toString());
  if (custom != null) return custom;

  final kind = item['kind']?.toString();
  switch (kind) {
    case 'holiday':
      return _defaultHoliday;
    case 'birthday':
      return _defaultBirthday;
    case 'custom':
      return _defaultEvent;
    default:
      return _defaultEvent;
  }
}

Color scheduleItemOnBlockColor(Color background) {
  return background.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
}

Color defaultScheduleCardColor({required bool isWorkout}) {
  return _defaultEvent;
}
