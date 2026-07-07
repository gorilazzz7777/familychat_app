/// Заглушки типов сезона — нужны только для компиляции календаря в режиме «события».
library;

class SeasonMonthDef {
  SeasonMonthDef({
    required this.year,
    required this.month,
  });

  final int year;
  final int month;

  DateTime get monthStart => DateTime(year, month, 1);
}

class StageMonthSegment {
  StageMonthSegment({
    required this.stage,
    required this.month,
    required this.segmentStart,
    required this.segmentEnd,
    required this.track,
  });

  final Map<String, dynamic> stage;
  final SeasonMonthDef month;
  final DateTime segmentStart;
  final DateTime segmentEnd;
  final int track;

  int get stageId => 0;
}

class SegmentPlacement {
  SegmentPlacement({
    required this.segment,
    required this.left,
    required this.width,
    required this.top,
    required this.calendarMode,
    required this.dateTicks,
  });

  final StageMonthSegment segment;
  final double left;
  final double width;
  final double top;
  final bool calendarMode;
  final List<({int day, double x})> dateTicks;
}

class MonthRowLayout {
  MonthRowLayout({
    required this.month,
    required this.placements,
    required this.calendarMode,
    required this.rowWidth,
    required this.trackCount,
    required this.dayWidth,
  });

  final SeasonMonthDef month;
  final List<SegmentPlacement> placements;
  final bool calendarMode;
  final double rowWidth;
  final int trackCount;
  final double dayWidth;

  double get rowHeight => 100;
}

DateTime seasonDateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
