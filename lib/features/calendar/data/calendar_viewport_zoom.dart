import 'dart:math' as math;

import 'package:flutter/material.dart';

enum CalendarContentMode { events, stages }

class ScheduleGridMetrics {
  const ScheduleGridMetrics({
    required this.columns,
    required this.visibleRows,
    required this.cellWidth,
    required this.cellHeight,
    required this.monthsOnScreen,
    this.weekOnlyViewport = false,
    this.dayOnlyViewport = false,
    this.singleMonthViewport = false,
  });

  final int columns;
  final int visibleRows;
  final double cellWidth;
  final double cellHeight;
  final int monthsOnScreen;
  final bool weekOnlyViewport;
  final bool dayOnlyViewport;
  /// Один месяц на весь экран (масштаб «1 месяц»).
  final bool singleMonthViewport;
}

/// Раскладка сетки месяцев расписания при pinch-zoom (день–12 месяцев для событий).
class ScheduleViewportZoom {
  const ScheduleViewportZoom._();

  static const double defaultMonthsCap = 6;
  static const double minMonthsSeason = 1;
  /// Один день в единицах «месяцев на экране» (1 / ~30 дней).
  static const double minMonthsDay = 1 / 30;
  /// Одна неделя в единицах «месяцев на экране» (7 / ~30 дней).
  static const double minMonthsWeek = 7 / 30;
  static const double _weekDayMidpoint = (minMonthsWeek + minMonthsDay) / 2;
  static const double maxMonths = 12;
  static const double gap = 6;
  static const double minCellWidth = 100;
  static const double minCellHeight = 88;

  static double minMonthsFor(CalendarContentMode mode) =>
      mode == CalendarContentMode.events ? minMonthsDay : minMonthsSeason;

  static bool isDayViewport(double monthsPerViewport, CalendarContentMode mode) =>
      mode == CalendarContentMode.events && monthsPerViewport < _weekDayMidpoint;

  static bool isWeekViewport(double monthsPerViewport, CalendarContentMode mode) =>
      mode == CalendarContentMode.events &&
      monthsPerViewport >= _weekDayMidpoint &&
      monthsPerViewport < 1;

  static bool isSingleMonthViewport(
    double monthsPerViewport,
    ScheduleGridMetrics metrics,
  ) =>
      monthsPerViewport >= 1 &&
      monthsPerViewport < 1.5 &&
      metrics.monthsOnScreen == 1 &&
      metrics.columns == 1 &&
      metrics.visibleRows == 1;

  static int maxMonthsThatFit(Size viewport) {
    var maxFit = 1;
    final maxCols = math.min(6, (viewport.width / minCellWidth).floor().clamp(1, 12));
    for (var cols = 1; cols <= maxCols; cols++) {
      final maxRows =
          ((viewport.height + gap) / (minCellHeight + gap)).floor().clamp(1, 12);
      maxFit = math.max(maxFit, cols * maxRows);
    }
    return maxFit.clamp(1, 12);
  }

  static double defaultMonthsFor(Size viewport) {
    return math.min(defaultMonthsCap, maxMonthsThatFit(viewport).toDouble());
  }

  static double defaultMonthsForMode(CalendarContentMode mode) =>
      mode == CalendarContentMode.events ? 1 : maxMonths;

  static ScheduleGridMetrics layout(
    Size viewport,
    double monthsPerViewport, {
    CalendarContentMode contentMode = CalendarContentMode.events,
  }) {
    if (isDayViewport(monthsPerViewport, contentMode)) {
      return ScheduleGridMetrics(
        columns: 1,
        visibleRows: 1,
        cellWidth: viewport.width,
        cellHeight: viewport.height,
        monthsOnScreen: 1,
        dayOnlyViewport: true,
      );
    }

    if (isWeekViewport(monthsPerViewport, contentMode)) {
      return ScheduleGridMetrics(
        columns: 1,
        visibleRows: 1,
        cellWidth: viewport.width,
        cellHeight: viewport.height,
        monthsOnScreen: 1,
        weekOnlyViewport: true,
      );
    }

    final target = monthsPerViewport.round().clamp(1, 12);
    final aspect = viewport.width / math.max(viewport.height, 1);

    var bestCols = 1;
    var bestScore = double.infinity;
    final maxCols = math.min(target, 6);

    for (var cols = 1; cols <= maxCols; cols++) {
      final rowsForTarget = (target / cols).ceil();
      final gridAspect = cols / rowsForTarget;
      final score = (gridAspect - aspect).abs();
      if (score < bestScore) {
        bestScore = score;
        bestCols = cols;
      }
    }

    final columns = bestCols;
    final rowsForTarget = (target / columns).ceil();
    final cellW = (viewport.width - (columns - 1) * gap) / columns;
    final cellH = (viewport.height - (rowsForTarget - 1) * gap) / rowsForTarget;
    final monthsOnScreen = math.min(target, columns * rowsForTarget);
    final singleMonth = target == 1 && columns == 1 && rowsForTarget == 1;

    return ScheduleGridMetrics(
      columns: columns,
      visibleRows: rowsForTarget,
      cellWidth: cellW,
      cellHeight: cellH,
      monthsOnScreen: monthsOnScreen,
      singleMonthViewport: singleMonth && contentMode == CalendarContentMode.events,
    );
  }
}
