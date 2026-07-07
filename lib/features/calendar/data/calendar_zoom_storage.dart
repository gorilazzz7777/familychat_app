import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_viewport_zoom.dart';

/// Сохранённый pinch-масштаб календаря familychat.
abstract final class ScheduleZoomStorage {
  static const _keyAgenda = 'familychat_calendar_months_per_viewport';
  static const double maxMonths = 12;

  static String _keyFor(CalendarContentMode mode) => _keyAgenda;

  static double minMonthsFor(CalendarContentMode mode) =>
      ScheduleViewportZoom.minMonthsFor(mode);

  static Future<double?> load(CalendarContentMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_keyFor(mode));
    if (value == null) return null;
    return value.clamp(minMonthsFor(mode), maxMonths);
  }

  static Future<void> save(
    double monthsPerViewport,
    CalendarContentMode mode,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _keyFor(mode),
      monthsPerViewport.clamp(minMonthsFor(mode), maxMonths),
    );
  }
}
