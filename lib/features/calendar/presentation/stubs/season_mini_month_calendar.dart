import 'package:flutter/material.dart';

import 'season_gantt_layout.dart';

/// Заглушка — режим «сезон» в familychat не используется.
class SeasonMiniMonthCalendar extends StatelessWidget {
  const SeasonMiniMonthCalendar({
    super.key,
    required this.month,
    required this.segments,
    required this.cellSize,
    this.selectedDay,
    this.rangeHighlightDayKeys = const {},
    this.onDayPointerDown,
    this.onDayPointerEnter,
    this.onDayTap,
    this.onDayLongPress,
    this.highlightToday = true,
    this.showWeekdayHeaders = false,
    this.editingStageId,
    this.editingMonthYear,
    this.editingMonthMonth,
    this.seasonStart,
    this.seasonEnd,
    this.onStageChanged,
    this.onStageCommit,
    this.onSegmentEnterEdit,
    this.onSegmentTap,
    this.onSegmentPointerDown,
  });

  final SeasonMonthDef month;
  final List<StageMonthSegment> segments;
  final Size cellSize;
  final DateTime? selectedDay;
  final Set<String> rangeHighlightDayKeys;
  final void Function(DateTime day)? onDayPointerDown;
  final void Function(DateTime day)? onDayPointerEnter;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onDayTap;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onDayLongPress;
  final bool highlightToday;
  final bool showWeekdayHeaders;
  final int? editingStageId;
  final int? editingMonthYear;
  final int? editingMonthMonth;
  final DateTime? seasonStart;
  final DateTime? seasonEnd;
  final void Function(int stageId, Map<String, dynamic> patch)? onStageChanged;
  final Future<void> Function(Map<String, dynamic> stage)? onStageCommit;
  final void Function(StageMonthSegment segment)? onSegmentEnterEdit;
  final void Function(StageMonthSegment segment)? onSegmentTap;
  final void Function(StageMonthSegment segment)? onSegmentPointerDown;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
