import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../data/calendar_agenda_utils.dart';
import '../../data/calendar_item_color.dart';
import '../../data/calendar_viewport_zoom.dart';
import '../../data/calendar_zoom_storage.dart';
import '../stubs/season_gantt_layout.dart';
import '../stubs/season_mini_month_calendar.dart';
import 'calendar_day_pointer_cell.dart';

export '../../data/calendar_viewport_zoom.dart' show CalendarContentMode;

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

enum _DayCellDensity { micro, compact, full }

_DayCellDensity _dayCellDensity(double height) {
  if (height < 28) return _DayCellDensity.micro;
  if (height < 42) return _DayCellDensity.compact;
  return _DayCellDensity.full;
}

bool _monthDayShowsEventText({
  required double height,
  required double width,
}) {
  if (height < 42 || width < 36) return false;
  if (math.min(height, width) < 34) return false;
  // На средних масштабах (много месяцев) ячейки узкие — только заливка, без подписей.
  if (width < 52 || height < 50) return false;
  return true;
}

Color _contrastTextOn(Color background) {
  return background.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
}

enum _GestureMode { idle, pinch }

enum _DragAxis { undecided, vertical, horizontal }

enum _PanAxis { horizontal, vertical }

/// Календарь расписания: pinch (неделя–12 месяцев для событий, 1–12 для сезона), влево/вправо — год, вверх/вниз — месяцы года.
class ScheduleCalendarPanel extends StatefulWidget {
  const ScheduleCalendarPanel({
    super.key,
    required this.focusedDay,
    required this.selectedDay,
    required this.itemsByDate,
    required this.onDaySelected,
    required this.onViewportChanged,
    this.onDayTap,
    this.onDayRangeSelected,
    this.rangeHighlightDayKeys = const {},
    this.onDayLongPress,
    this.multiSelectMode = false,
    this.contentMode = CalendarContentMode.events,
    this.seasonMonthsByIndex = const {},
    this.seasonMonthsForYear,
    this.onSeasonDayTap,
    this.onSeasonDayLongPress,
    this.seasonEditingStageId,
    this.seasonEditingMonthYear,
    this.seasonEditingMonthMonth,
    this.seasonClampStart,
    this.seasonClampEnd,
    this.onSeasonStageChanged,
    this.onSeasonStageCommit,
    this.onSeasonSegmentEnterEdit,
    this.onSeasonSegmentTap,
    this.readOnly = false,
    this.onSelectionModeChanged,
    this.onZoomGesture,
    this.onAgendaItemTap,
  });

  final DateTime focusedDay;
  final DateTime selectedDay;
  final Map<String, List<Map<String, dynamic>>> itemsByDate;
  final void Function(DateTime selected, DateTime focused) onDaySelected;
  final void Function(
    int year,
    int monthStartIndex,
    double monthsPerViewport, {
    required bool yearChanged,
    required bool dayOnlyViewport,
  }) onViewportChanged;
  final void Function(DateTime day)? onDayTap;
  final void Function(DateTime start, DateTime end)? onDayRangeSelected;
  final Set<String> rangeHighlightDayKeys;
  final void Function(DateTime day)? onDayLongPress;
  final bool multiSelectMode;
  final CalendarContentMode contentMode;
  final Map<int, MonthRowLayout> seasonMonthsByIndex;
  final Map<int, MonthRowLayout> Function(int year)? seasonMonthsForYear;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onSeasonDayTap;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onSeasonDayLongPress;
  final int? seasonEditingStageId;
  final int? seasonEditingMonthYear;
  final int? seasonEditingMonthMonth;
  final DateTime? seasonClampStart;
  final DateTime? seasonClampEnd;
  final void Function(int stageId, Map<String, dynamic> patch)? onSeasonStageChanged;
  final Future<void> Function(Map<String, dynamic> stage)? onSeasonStageCommit;
  final void Function(StageMonthSegment segment)? onSeasonSegmentEnterEdit;
  final void Function(StageMonthSegment segment)? onSeasonSegmentTap;
  final bool readOnly;
  final ValueChanged<bool>? onSelectionModeChanged;
  final VoidCallback? onZoomGesture;
  final void Function(DateTime day, Map<String, dynamic> item)? onAgendaItemTap;

  static String dateKey(DateTime d) => AgendaUtils.dateKey(d);

  static DateTime monthStart(DateTime day) => DateTime(day.year, day.month, 1);

  @override
  State<ScheduleCalendarPanel> createState() => _ScheduleCalendarPanelState();
}

class _ScheduleCalendarPanelState extends State<ScheduleCalendarPanel> {
  static const _minYear = 2020;
  static const _maxYear = 2032;
  static const _minPinchSpan = 56.0;
  static const _pinchScaleThreshold = 0.07;
  static const _dragSlop = 12.0;
  static const _selectionArmDelay = Duration(milliseconds: 400);
  static const _longPressMovementGrace = Duration(milliseconds: 350);
  static const _panCommitMinRows = 0.28;
  static const _panTwoRowThreshold = 1.35;

  double _monthsPerViewport = 1;
  double _pinchBaseMonths = 1;
  late int _displayYear;
  bool _zoomBootstrapComplete = false;
  bool _zoomBootstrapInFlight = false;
  bool _zoomUserTouched = false;

  final Map<int, Offset> _pointerLocations = {};
  double? _pinchStartDistance;
  _GestureMode _gestureMode = _GestureMode.idle;
  bool _pinchCommitted = false;
  Size? _cachedViewport;
  late PageController _yearPageController;
  final Map<int, int> _monthStartByYear = {};
  DateTime? _rangeAnchor;
  DateTime? _rangeFocus;
  bool _rangeSelecting = false;
  final CalendarDayHitRegistry _dayHitRegistry = CalendarDayHitRegistry();
  Offset? _dragStart;
  DateTime? _pendingRangeDay;
  _DragAxis _dragAxis = _DragAxis.undecided;
  bool _scrollLocked = false;
  bool _tabSwipeBlocked = false;
  Timer? _longPressTimer;
  Timer? _selectionArmTimer;
  bool _selectionArmed = false;
  bool _longPressTriggered = false;
  int? _pendingSeasonEditScrollMonth;
  bool _panBlocked = false;
  Offset? _panOrigin;
  _PanAxis? _panAxis;
  bool _isPanning = false;
  bool _weekPanMode = false;
  bool _dayPanMode = false;
  bool _dayAgendaAtTop = true;
  bool _dayAgendaAtBottom = true;
  int _panAnchorMonthStart = 0;
  Offset _panOffset = Offset.zero;

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _cancelSelectionArmTimer() {
    _selectionArmTimer?.cancel();
    _selectionArmTimer = null;
  }

  void _disarmSelection() {
    _cancelSelectionArmTimer();
    _selectionArmed = false;
  }

  /// Ждём второй палец для pinch; затем — движение для drag; иначе long-press.
  void _armSelectionGesture() {
    _disarmSelection();
    _cancelLongPressTimer();
    if (widget.readOnly) return;
    final canRange = widget.onDayRangeSelected != null &&
        !(widget.contentMode == CalendarContentMode.stages &&
            widget.seasonEditingStageId != null);
    final canLongPress = widget.onDayLongPress != null;
    if (!canRange && !canLongPress) return;

    _selectionArmTimer = Timer(_selectionArmDelay, () {
      if (!mounted) return;
      if (_pointerLocations.length != 1) return;
      if (_gestureMode == _GestureMode.pinch) return;
      if (canRange) {
        _selectionArmed = true;
      }
      final start = _dragStart;
      if (start == null) return;
      final current = _pointerLocations.values.first;
      if ((current - start).distance >= _dragSlop) {
        _resolveDragAxis(current);
        return;
      }
      if (canLongPress && _pendingRangeDay != null) {
        _scheduleLongPressAfterArm();
      }
    });
  }

  void _markLongPressGesture() {
    _longPressTriggered = true;
    _cancelLongPressTimer();
    _cancelRangeSelection();
    _setScrollLocked(false);
    _setTabSwipeBlocked(true);
    _dragAxis = _DragAxis.undecided;
    _pendingRangeDay = null;
    _dragStart = null;
  }

  void _scheduleLongPressAfterArm() {
    _cancelLongPressTimer();
    final day = _pendingRangeDay;
    if (day == null || widget.onDayLongPress == null) return;
    _longPressTimer = Timer(_longPressMovementGrace, () {
      if (!mounted) return;
      if (_pointerLocations.length != 1 || _gestureMode == _GestureMode.pinch) {
        return;
      }
      if (_isPanning || _rangeSelecting) return;
      final start = _dragStart;
      final current = _pointerLocations.values.firstOrNull;
      if (start != null &&
          current != null &&
          (current - start).distance >= _dragSlop) {
        return;
      }
      _markLongPressGesture();
      HapticFeedback.mediumImpact();
      widget.onDayLongPress!(day);
    });
  }

  void Function(DateTime day, List<StageMonthSegment> daySegments)?
      _wrapSeasonDayLongPress(
    void Function(DateTime day, List<StageMonthSegment> daySegments)? callback,
  ) {
    if (callback == null) return null;
    return (day, segments) {
      _markLongPressGesture();
      callback(day, segments);
    };
  }

  void Function(StageMonthSegment segment)? _wrapSeasonSegmentEnterEdit(
    void Function(StageMonthSegment segment)? callback,
  ) {
    if (callback == null) return null;
    return (segment) {
      _markLongPressGesture();
      callback(segment);
    };
  }

  void _setTabSwipeBlocked(bool blocked) {
    if (_tabSwipeBlocked == blocked) return;
    _tabSwipeBlocked = blocked;
    widget.onSelectionModeChanged?.call(blocked);
  }

  void _setScrollLocked(bool locked) {
    if (_scrollLocked == locked) return;
    _scrollLocked = locked;
  }

  Set<String> get _activeRangeKeys {
    if (!_rangeSelecting || _rangeAnchor == null || _rangeFocus == null) {
      return widget.rangeHighlightDayKeys;
    }
    return _dayKeysInclusive(_rangeAnchor!, _rangeFocus!);
  }

  static Set<String> _dayKeysInclusive(DateTime a, DateTime b) {
    final start = _dateOnly(a.isBefore(b) ? a : b);
    final end = _dateOnly(a.isBefore(b) ? b : a);
    final keys = <String>{};
    var cursor = start;
    while (!cursor.isAfter(end)) {
      keys.add(AgendaUtils.dateKey(cursor));
      cursor = cursor.add(const Duration(days: 1));
    }
    return keys;
  }

  void _onDayPointerDown(DateTime day) {
    _pendingRangeDay = _dateOnly(day);
    if (widget.contentMode == CalendarContentMode.stages || !widget.multiSelectMode) {
      _setTabSwipeBlocked(true);
    }
  }

  void _onSeasonSegmentPointerDown(StageMonthSegment segment) {
    _setTabSwipeBlocked(true);
  }

  void _onDayPointerEnter(DateTime day) {
    if (!_rangeSelecting || widget.readOnly || _dragAxis == _DragAxis.vertical) {
      return;
    }
    final next = _dateOnly(day);
    if (_rangeFocus == next) return;
    setState(() => _rangeFocus = next);
  }

  void _cancelRangeSelection() {
    if (!_rangeSelecting && _rangeAnchor == null && _rangeFocus == null) return;
    _rangeSelecting = false;
    _rangeAnchor = null;
    _rangeFocus = null;
    setState(() {});
  }

  void _resolveDragAxis(Offset current) {
    if (_dragAxis != _DragAxis.undecided || _panAxis != null) return;
    final start = _dragStart;
    if (start == null) return;
    final delta = current - start;
    if (delta.distance < _dragSlop) return;

    final horizontal = delta.dx.abs() >= delta.dy.abs();

    if (horizontal && _canStartRangeSelection()) {
      if (!_selectionArmed) return;
      _dragAxis = _DragAxis.horizontal;
      _cancelLongPressTimer();
      _setScrollLocked(true);
      _rangeAnchor = _pendingRangeDay;
      _rangeFocus = _pendingRangeDay;
      _rangeSelecting = true;
      setState(() {});
      return;
    }

    if (_isDayViewport()) {
      if (horizontal || _dayVerticalPanAllowed(delta.dy)) {
        _startDayPan(
          start: start,
          delta: delta,
          vertical: !horizontal,
        );
      }
      return;
    }

    if (!horizontal && _isWeekViewport()) {
      _disarmSelection();
      _cancelLongPressTimer();
      _pendingRangeDay = null;
      _setTabSwipeBlocked(true);
      _cancelRangeSelection();
      _isPanning = true;
      _weekPanMode = true;
      _dayPanMode = false;
      _panOrigin = start;
      _panOffset = Offset(0, delta.dy);
      _panAxis = _PanAxis.vertical;
      setState(() {});
      return;
    }

    if (!_navigationPanEnabled) return;
    if (horizontal && widget.contentMode == CalendarContentMode.stages) return;
    if (horizontal && _pendingRangeDay != null && !_selectionArmed) return;
    if (!horizontal && !_canPanVertically()) return;

    _cancelLongPressTimer();
    _pendingRangeDay = null;
    _setTabSwipeBlocked(true);
    _cancelRangeSelection();
    _isPanning = true;
    _panOrigin = start;
    _panAnchorMonthStart = _monthStartForYear(_displayYear);
    _panOffset = horizontal ? Offset(delta.dx, 0) : Offset(0, delta.dy);
    _panAxis = horizontal ? _PanAxis.horizontal : _PanAxis.vertical;
    setState(() {});
  }

  bool _canStartRangeSelection() {
    if (_pendingRangeDay == null ||
        widget.readOnly ||
        widget.multiSelectMode ||
        widget.onDayRangeSelected == null) {
      return false;
    }
    if (widget.contentMode == CalendarContentMode.stages &&
        widget.seasonEditingStageId != null) {
      return false;
    }
    return true;
  }

  bool get _navigationPanEnabled {
    final viewport = _cachedViewport;
    if (viewport == null) return false;
    final metrics = _layoutMetrics(viewport);
    return !metrics.weekOnlyViewport && !metrics.dayOnlyViewport;
  }

  bool _isWeekViewport() {
    final viewport = _cachedViewport;
    if (viewport == null) return false;
    return _layoutMetrics(viewport).weekOnlyViewport;
  }

  bool _isDayViewport() {
    final viewport = _cachedViewport;
    if (viewport == null) return false;
    return _layoutMetrics(viewport).dayOnlyViewport;
  }

  bool _isAgendaDetailViewport() => _isWeekViewport() || _isDayViewport();

  bool _dayVerticalPanAllowed(double dy) {
    if (dy < 0) return _dayAgendaAtBottom;
    if (dy > 0) return _dayAgendaAtTop;
    return true;
  }

  void _onDayAgendaScrollEdges({required bool atTop, required bool atBottom}) {
    if (_dayAgendaAtTop == atTop && _dayAgendaAtBottom == atBottom) return;
    setState(() {
      _dayAgendaAtTop = atTop;
      _dayAgendaAtBottom = atBottom;
    });
  }

  void _startDayPan({
    required Offset start,
    required Offset delta,
    required bool vertical,
  }) {
    _disarmSelection();
    _cancelLongPressTimer();
    _pendingRangeDay = null;
    _setTabSwipeBlocked(true);
    _cancelRangeSelection();
    _isPanning = true;
    _dayPanMode = true;
    _weekPanMode = false;
    _panOrigin = start;
    _panOffset = vertical ? Offset(0, delta.dy) : Offset(delta.dx, 0);
    _panAxis = vertical ? _PanAxis.vertical : _PanAxis.horizontal;
    setState(() {});
  }

  double get _weekPanStep {
    final viewport = _cachedViewport;
    if (viewport == null) return 1;
    final metrics = _layoutMetrics(viewport);
    return metrics.weekOnlyViewport ? metrics.cellHeight : viewport.height;
  }

  Offset _weekPanPreview() {
    if (!_isPanning || !_weekPanMode) return Offset.zero;
    final step = _weekPanStep;
    final wholeWeeks = (-_panOffset.dy / step).truncate();
    return Offset(0, _panOffset.dy + wholeWeeks * step);
  }

  Offset _dayPanPreview() {
    if (!_isPanning || !_dayPanMode) return Offset.zero;
    final viewport = _cachedViewport;
    final vertical = _panAxis == _PanAxis.vertical;
    final step = vertical ? (viewport?.height ?? 1) : (viewport?.width ?? 1);
    final delta = vertical ? _panOffset.dy : _panOffset.dx;
    final wholeDays = (-delta / step).truncate();
    final remainder = vertical
        ? Offset(0, delta + wholeDays * step)
        : Offset(delta + wholeDays * step, 0);
    return remainder;
  }

  void _finishDayPan() {
    final viewport = _cachedViewport;
    if (viewport == null) {
      setState(_resetPan);
      return;
    }
    final vertical = _panAxis == _PanAxis.vertical;
    final step = vertical ? viewport.height : viewport.width;
    final delta = vertical ? _panOffset.dy : _panOffset.dx;
    if (step <= 0) {
      setState(_resetPan);
      return;
    }

    var wholeDays = (-delta / step).truncate();
    if (wholeDays == 0) {
      if (delta.abs() / step < _panCommitMinRows) {
        setState(_resetPan);
        return;
      }
      wholeDays = delta < 0 ? 1 : -1;
    }

    HapticFeedback.mediumImpact();
    final newDay = _dateOnly(
      widget.selectedDay.add(Duration(days: wholeDays)),
    );
    widget.onDaySelected(newDay, newDay);
    if (newDay.year != _displayYear) {
      _goToYear(newDay.year);
    }
    setState(() {
      _dayAgendaAtTop = true;
      _dayAgendaAtBottom = true;
      _resetPan();
    });
  }

  void _finishWeekPan() {
    final step = _weekPanStep;
    final delta = _panOffset.dy;
    final absWeeks = delta.abs() / step;
    if (absWeeks < _panCommitMinRows) {
      setState(_resetPan);
      return;
    }
    final steps = absWeeks < _panTwoRowThreshold ? 1 : 2;
    final weekDir = delta < 0 ? steps : -steps;
    final newDay = _dateOnly(widget.selectedDay.add(Duration(days: 7 * weekDir)));
    HapticFeedback.mediumImpact();
    widget.onDaySelected(newDay, newDay);
    if (newDay.year != _displayYear) {
      _goToYear(newDay.year);
    }
    setState(_resetPan);
  }

  bool _canPanVertically() {
    if (!_navigationPanEnabled) return false;
    final viewport = _cachedViewport;
    if (viewport == null) return false;
    return _gridCapacity(_layoutMetrics(viewport)) < 12;
  }

  int _monthStartForYear(int year) => _monthStartByYear[year] ?? 0;

  void _setMonthStartForYear(int year, int start, int gridCapacity) {
    _monthStartByYear[year] = start.clamp(0, _maxMonthStart(gridCapacity));
  }

  int _alignedMonthStart(int monthIndex, ScheduleGridMetrics metrics, int gridCapacity) {
    final maxStart = _maxMonthStart(gridCapacity);
    if (gridCapacity >= 12) return 0;
    final row = monthIndex ~/ metrics.columns;
    return (row * metrics.columns).clamp(0, maxStart);
  }

  DateTime _anchorDayForYear(int year) {
    final fromSelection = _medianHighlightedDay(year: year);
    if (fromSelection != null) return fromSelection;

    final today = _dateOnly(DateTime.now());
    if (year == today.year) return today;
    final focused = _dateOnly(widget.focusedDay);
    if (focused.year == year) return focused;
    final selected = _dateOnly(widget.selectedDay);
    if (selected.year == year) return selected;
    return DateTime(year, 6, 15);
  }

  List<DateTime> _highlightedDays() {
    if (!widget.multiSelectMode || widget.rangeHighlightDayKeys.isEmpty) {
      return const [];
    }
    final dates = <DateTime>[];
    for (final key in widget.rangeHighlightDayKeys) {
      final parsed = DateTime.tryParse(key);
      if (parsed != null) dates.add(_dateOnly(parsed));
    }
    dates.sort();
    return dates;
  }

  DateTime? _medianHighlightedDay({int? year}) {
    final dates = year == null
        ? _highlightedDays()
        : _highlightedDays().where((d) => d.year == year).toList();
    if (dates.isEmpty) return null;
    return dates[dates.length ~/ 2];
  }

  int _monthStartForAnchor(
    int monthIndex,
    ScheduleGridMetrics metrics,
    int gridCapacity,
  ) {
    final maxStart = _maxMonthStart(gridCapacity);
    if (gridCapacity >= 12) return 0;

    final visible = metrics.monthsOnScreen.clamp(1, gridCapacity);
    var start = (monthIndex - visible ~/ 2).clamp(0, maxStart);
    start = _alignedMonthStart(start, metrics, gridCapacity);

    if (monthIndex < start) {
      start = _alignedMonthStart(monthIndex, metrics, gridCapacity);
    } else if (monthIndex >= start + visible) {
      final bottomStart = (monthIndex - visible + 1).clamp(0, maxStart);
      start = _alignedMonthStart(bottomStart, metrics, gridCapacity);
      if (monthIndex >= start + visible) {
        start = ((monthIndex - visible + 1) ~/ metrics.columns) * metrics.columns;
        start = start.clamp(0, maxStart);
      }
    }
    return start;
  }

  void _refocusAfterZoom(ScheduleGridMetrics metrics, int gridCapacity) {
    if (metrics.dayOnlyViewport || metrics.weekOnlyViewport) {
      final anchor = _medianHighlightedDay() ?? _anchorDayForYear(_displayYear);
      if (anchor.year != _displayYear) {
        _goToYear(anchor.year);
      }
      if (!_isSameDay(anchor, widget.selectedDay)) {
        widget.onDaySelected(anchor, anchor);
      }
      return;
    }

    final selectionAnchor = _medianHighlightedDay();
    if (selectionAnchor != null && selectionAnchor.year != _displayYear) {
      _goToYear(selectionAnchor.year);
    }

    final years = {
      ..._monthStartByYear.keys,
      _displayYear,
      if (selectionAnchor != null) selectionAnchor.year,
    };
    for (final year in years) {
      final anchor = _anchorDayForYear(year);
      _setMonthStartForYear(
        year,
        _monthStartForAnchor(anchor.month - 1, metrics, gridCapacity),
        gridCapacity,
      );
    }
  }

  void _ensureMonthStartForYear(int year, ScheduleGridMetrics metrics, int gridCapacity) {
    if (_monthStartByYear.containsKey(year)) return;
    final anchor = _anchorDayForYear(year);
    _monthStartByYear[year] =
        _monthStartForAnchor(anchor.month - 1, metrics, gridCapacity);
  }

  ({int displayStart, Offset translate}) _panPreview({
    required ScheduleGridMetrics metrics,
    required int gridCapacity,
    required int year,
  }) {
    final maxStart = _maxMonthStart(gridCapacity);
    if (year != _displayYear || !_isPanning || _panAxis == null) {
      return (
        displayStart: _monthStartForYear(year).clamp(0, maxStart),
        translate: Offset.zero,
      );
    }

    final rowStep = metrics.cellHeight + ScheduleViewportZoom.gap;
    final colStep = metrics.cellWidth + ScheduleViewportZoom.gap;
    final cols = metrics.columns;
    if (_panAxis == _PanAxis.vertical) {
      final wholeRows = (-_panOffset.dy / rowStep).truncate();
      return (
        displayStart: (_panAnchorMonthStart + wholeRows * cols).clamp(0, maxStart),
        translate: Offset(0, _panOffset.dy + wholeRows * rowStep),
      );
    }

    final wholeCols = (-_panOffset.dx / colStep).truncate();
    return (
      displayStart: (_panAnchorMonthStart + wholeCols).clamp(0, maxStart),
      translate: Offset(_panOffset.dx + wholeCols * colStep, 0),
    );
  }

  void _resetPan() {
    _panOrigin = null;
    _panAxis = null;
    _isPanning = false;
    _weekPanMode = false;
    _dayPanMode = false;
    _panOffset = Offset.zero;
    _panBlocked = false;
  }

  void _finishPan({
    required ScheduleGridMetrics metrics,
    required int gridCapacity,
  }) {
    if (!_isPanning || _panAxis == null) {
      _resetPan();
      return;
    }

    if (_dayPanMode) {
      _finishDayPan();
      _notifyViewport(metrics: metrics);
      return;
    }

    if (_weekPanMode) {
      _finishWeekPan();
      _notifyViewport(metrics: metrics);
      return;
    }

    final maxStart = _maxMonthStart(gridCapacity);
    final rowStep = metrics.cellHeight + ScheduleViewportZoom.gap;
    final colStep = metrics.cellWidth + ScheduleViewportZoom.gap;
    final cols = metrics.columns;

    if (_panAxis == _PanAxis.vertical) {
      final delta = _panOffset.dy;
      final absRows = delta.abs() / rowStep;
      if (absRows < _panCommitMinRows) {
        setState(_resetPan);
        return;
      }
      final steps = absRows < _panTwoRowThreshold ? 1 : 2;
      final rowDir = delta < 0 ? steps : -steps;
      var newStart = _panAnchorMonthStart + rowDir * cols;

      if (newStart < 0) {
        if (_displayYear > _minYear) {
          HapticFeedback.mediumImpact();
          final prevYear = _displayYear - 1;
          _setMonthStartForYear(prevYear, maxStart, gridCapacity);
          _goToYear(prevYear);
        }
        setState(_resetPan);
        _notifyViewport(metrics: metrics);
        return;
      }

      if (newStart > maxStart) {
        if (_displayYear < _maxYear) {
          HapticFeedback.mediumImpact();
          _setMonthStartForYear(_displayYear + 1, 0, gridCapacity);
          _goToYear(_displayYear + 1);
        }
        setState(_resetPan);
        _notifyViewport(metrics: metrics);
        return;
      }

      HapticFeedback.mediumImpact();
      setState(() {
        _setMonthStartForYear(_displayYear, newStart, gridCapacity);
        _resetPan();
      });
      _notifyViewport(metrics: metrics);
      return;
    }

    final delta = _panOffset.dx;
    final absCols = delta.abs() / colStep;
    if (absCols < _panCommitMinRows) {
      setState(_resetPan);
      return;
    }

    final steps = absCols < _panTwoRowThreshold ? 1 : 2;
    final colDir = delta < 0 ? steps : -steps;
    var newStart = _panAnchorMonthStart + colDir;

    if (newStart < 0) {
      if (_displayYear > _minYear) {
        HapticFeedback.mediumImpact();
        final prevYear = _displayYear - 1;
        _setMonthStartForYear(prevYear, maxStart, gridCapacity);
        _goToYear(prevYear);
      }
      setState(_resetPan);
      _notifyViewport(metrics: metrics);
      return;
    }

    if (newStart > maxStart) {
      if (_displayYear < _maxYear) {
        HapticFeedback.mediumImpact();
        _setMonthStartForYear(_displayYear + 1, 0, gridCapacity);
        _goToYear(_displayYear + 1);
      }
      setState(_resetPan);
      _notifyViewport(metrics: metrics);
      return;
    }

    HapticFeedback.mediumImpact();
    setState(() {
      _setMonthStartForYear(_displayYear, newStart, gridCapacity);
      _resetPan();
    });
    _notifyViewport(metrics: metrics);
  }

  void _finishRangeSelection() {
    if (!_rangeSelecting) return;
    final anchor = _rangeAnchor;
    final focus = _rangeFocus;
    _rangeSelecting = false;
    _rangeAnchor = null;
    _rangeFocus = null;
    setState(() {});
    if (anchor == null || focus == null) return;

    final start = _dateOnly(anchor.isBefore(focus) ? anchor : focus);
    final end = _dateOnly(anchor.isBefore(focus) ? focus : anchor);
    widget.onDaySelected(start, start);
    if (start == end) {
      widget.onDayTap?.call(start);
    } else if (!widget.readOnly) {
      widget.onDayRangeSelected?.call(start, end);
    } else {
      widget.onDayTap?.call(end);
    }
  }

  @override
  void initState() {
    super.initState();
    _displayYear = widget.focusedDay.year;
    _monthsPerViewport =
        ScheduleViewportZoom.defaultMonthsForMode(widget.contentMode);
    _pinchBaseMonths = _monthsPerViewport;
    _yearPageController = PageController(initialPage: _displayYear - _minYear);
  }

  void _markZoomUserTouched() => _zoomUserTouched = true;

  Future<void> _bootstrapZoomIfNeeded(Size viewport) async {
    if (_zoomBootstrapComplete || _zoomUserTouched || _zoomBootstrapInFlight) return;
    if (viewport.width <= 0 || viewport.height <= 0) return;
    _zoomBootstrapInFlight = true;
    try {
      final saved = await ScheduleZoomStorage.load(widget.contentMode);
      if (!mounted || _zoomUserTouched) return;
      final resolved =
          saved ?? ScheduleViewportZoom.defaultMonthsFor(viewport);
      setState(() {
        _monthsPerViewport = resolved;
        _pinchBaseMonths = resolved;
        _zoomBootstrapComplete = true;
        final metrics = _layoutMetrics(viewport);
        _refocusAfterZoom(metrics, _gridCapacity(metrics));
      });
      _notifyViewport();
    } finally {
      _zoomBootstrapInFlight = false;
    }
  }

  @override
  void dispose() {
    _cancelLongPressTimer();
    _cancelSelectionArmTimer();
    _yearPageController.dispose();
    super.dispose();
  }

  double get _effectiveMonthsPerViewport {
    if (widget.contentMode == CalendarContentMode.stages) {
      return _monthsPerViewport.clamp(ScheduleViewportZoom.minMonthsSeason, ScheduleViewportZoom.maxMonths);
    }
    return _monthsPerViewport;
  }

  ScheduleGridMetrics _layoutMetrics(Size viewport) => ScheduleViewportZoom.layout(
        viewport,
        _effectiveMonthsPerViewport,
        contentMode: widget.contentMode,
      );

  void _completeSeasonEditFocus() {
    if (!mounted || _pendingSeasonEditScrollMonth == null) return;
    final viewport = _cachedViewport;
    if (viewport == null) return;
    final metrics = _layoutMetrics(viewport);
    final gridCapacity = _gridCapacity(metrics);
    final editYear = widget.seasonEditingMonthYear ?? _displayYear;
    _setMonthStartForYear(
      editYear,
      _alignedMonthStart(_pendingSeasonEditScrollMonth!, metrics, gridCapacity),
      gridCapacity,
    );
    _pendingSeasonEditScrollMonth = null;
    setState(() {});
    _notifyViewport(metrics: metrics);
  }

  void _handleSeasonEditModeChange(ScheduleCalendarPanel oldWidget) {
    if (widget.contentMode != CalendarContentMode.stages) return;

    final wasEditing = oldWidget.seasonEditingStageId != null;
    final isEditing = widget.seasonEditingStageId != null;

    if (!wasEditing &&
        isEditing &&
        widget.seasonEditingMonthYear != null &&
        widget.seasonEditingMonthMonth != null) {
      final editYear = widget.seasonEditingMonthYear!;
      if (editYear != _displayYear) {
        _displayYear = editYear;
        final page = (_displayYear - _minYear).clamp(0, _maxYear - _minYear);
        if (_yearPageController.hasClients) {
          _yearPageController.jumpToPage(page);
        }
      }
      _pendingSeasonEditScrollMonth = widget.seasonEditingMonthMonth! - 1;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _completeSeasonEditFocus();
      });
      return;
    }

    if (wasEditing && !isEditing) {
      _pendingSeasonEditScrollMonth = null;
    }
  }

  @override
  void didUpdateWidget(covariant ScheduleCalendarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusedDay.year != widget.focusedDay.year &&
        widget.focusedDay.year != _displayYear) {
      _displayYear = widget.focusedDay.year;
      final page = (_displayYear - _minYear).clamp(0, _maxYear - _minYear);
      if (_yearPageController.hasClients) {
        _yearPageController.jumpToPage(page);
      }
    }
    _handleSeasonEditModeChange(oldWidget);
    if (!_isSameDay(oldWidget.selectedDay, widget.selectedDay)) {
      _dayAgendaAtTop = true;
      _dayAgendaAtBottom = true;
    }
  }

  int _gridCapacity(ScheduleGridMetrics metrics) =>
      math.min(12, metrics.columns * metrics.visibleRows);

  int _maxMonthStart(int gridCapacity) => math.max(0, 12 - gridCapacity);

  Map<int, MonthRowLayout> _seasonMonthsFor(int year) =>
      widget.seasonMonthsForYear?.call(year) ?? widget.seasonMonthsByIndex;

  int _monthStartIndexFor(ScheduleGridMetrics metrics, int gridCapacity, int year) {
    return _monthStartForYear(year).clamp(0, _maxMonthStart(gridCapacity));
  }

  void _notifyViewport({bool yearChanged = false, ScheduleGridMetrics? metrics}) {
    final m = metrics ??
        (_cachedViewport != null ? _layoutMetrics(_cachedViewport!) : null);
    final gridCapacity = m != null ? _gridCapacity(m) : 12;
    widget.onViewportChanged(
      _displayYear,
      m != null ? _monthStartIndexFor(m, gridCapacity, _displayYear) : 0,
      _effectiveMonthsPerViewport,
      yearChanged: yearChanged,
      dayOnlyViewport: m?.dayOnlyViewport ?? false,
    );
  }

  void _onYearPageChanged(int page) {
    final newYear = (_minYear + page).clamp(_minYear, _maxYear);
    if (newYear == _displayYear) return;
    setState(() => _displayYear = newYear);
    _notifyViewport(yearChanged: true);
  }

  void _goToYear(int year) {
    final target = year.clamp(_minYear, _maxYear);
    if (target == _displayYear || !_yearPageController.hasClients) return;
    _yearPageController.animateToPage(
      target - _minYear,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _notifyZoomGesture() => widget.onZoomGesture?.call();

  bool _canZoomIn() {
    if (ScheduleViewportZoom.isDayViewport(_monthsPerViewport, widget.contentMode)) {
      return false;
    }
    if (widget.contentMode == CalendarContentMode.events) {
      return true;
    }
    return _monthsPerViewport > ScheduleViewportZoom.minMonthsSeason;
  }

  bool _canZoomOut(Size viewport) {
    if (ScheduleViewportZoom.isDayViewport(_monthsPerViewport, widget.contentMode) ||
        ScheduleViewportZoom.isWeekViewport(_monthsPerViewport, widget.contentMode)) {
      return true;
    }
    final maxFit = ScheduleViewportZoom.maxMonthsThatFit(viewport).toDouble();
    final maxZoom = math.min(ScheduleViewportZoom.maxMonths, maxFit);
    return _monthsPerViewport < maxZoom;
  }

  void _stepZoom({required bool zoomIn}) {
    final viewport = _cachedViewport;
    if (viewport == null) return;
    _markZoomUserTouched();
    final minZoom = ScheduleViewportZoom.minMonthsFor(widget.contentMode);
    final maxFit = ScheduleViewportZoom.maxMonthsThatFit(viewport).toDouble();
    final maxZoom = math.min(ScheduleViewportZoom.maxMonths, maxFit);
    final isDay =
        ScheduleViewportZoom.isDayViewport(_monthsPerViewport, widget.contentMode);
    final isWeek =
        ScheduleViewportZoom.isWeekViewport(_monthsPerViewport, widget.contentMode);

    final double next;
    if (zoomIn) {
      if (isDay) return;
      if (isWeek) {
        next = ScheduleViewportZoom.minMonthsDay;
      } else if (_monthsPerViewport <= 1 &&
          widget.contentMode == CalendarContentMode.events) {
        next = ScheduleViewportZoom.minMonthsWeek;
      } else {
        next = (_monthsPerViewport - 1).clamp(minZoom, maxZoom);
      }
    } else {
      if (isDay) {
        next = ScheduleViewportZoom.minMonthsWeek;
      } else if (isWeek) {
        next = 1;
      } else {
        next = (_monthsPerViewport + 1).clamp(minZoom, maxZoom);
      }
    }

    if (next == _monthsPerViewport) return;

    _notifyZoomGesture();
    setState(() {
      _monthsPerViewport = next;
      _pinchBaseMonths = next;
      final newMetrics = _layoutMetrics(viewport);
      _refocusAfterZoom(newMetrics, _gridCapacity(newMetrics));
    });
    _notifyViewport(metrics: _layoutMetrics(viewport));
    unawaited(ScheduleZoomStorage.save(_monthsPerViewport, widget.contentMode));
  }

  void _handleDayTap(DateTime day) {
    widget.onDaySelected(day, day);
    if (_isDayViewport()) return;
    widget.onDayTap?.call(day);
  }

  void _resetGestureState() {
    _gestureMode = _GestureMode.idle;
    _pinchStartDistance = null;
    _pinchCommitted = false;
    _dragStart = null;
    _dragAxis = _DragAxis.undecided;
    _pendingRangeDay = null;
    _longPressTriggered = false;
    _cancelLongPressTimer();
    _disarmSelection();
    _setScrollLocked(false);
    _setTabSwipeBlocked(false);
    _resetPan();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.contentMode == CalendarContentMode.stages &&
        widget.seasonEditingStageId != null) {
      return;
    }
    _pointerLocations[event.pointer] = event.position;
    if (_pointerLocations.length == 1) {
      _dragStart = event.position;
      _dragAxis = _DragAxis.undecided;
      _panAxis = null;
      _isPanning = false;
      _panOffset = Offset.zero;
      _panBlocked = false;
      _setScrollLocked(false);
      _longPressTriggered = false;
      final hitDay = _dayHitRegistry.dayAt(event.position);
      if (hitDay != null) {
        _pendingRangeDay = _dateOnly(hitDay);
      }
      _armSelectionGesture();
      final seasonGestures =
          widget.contentMode == CalendarContentMode.stages && !widget.readOnly;
      if (_navigationPanEnabled || seasonGestures || _isAgendaDetailViewport()) {
        _setTabSwipeBlocked(true);
      }
    }
    if (_pointerLocations.length >= 2) {
      _disarmSelection();
      _notifyZoomGesture();
      if (_rangeSelecting) {
        _cancelRangeSelection();
      }
      _dragAxis = _DragAxis.undecided;
      _pendingRangeDay = null;
      _setScrollLocked(false);
      _setTabSwipeBlocked(false);
      _panBlocked = true;
      _resetPan();
      _gestureMode = _GestureMode.pinch;
      _pinchCommitted = false;
      _pinchStartDistance = math.max(_pointerSpan(), _minPinchSpan);
      _pinchBaseMonths = _monthsPerViewport;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (widget.contentMode == CalendarContentMode.stages &&
        widget.seasonEditingStageId != null) {
      return;
    }
    if (!_pointerLocations.containsKey(event.pointer)) return;
    _pointerLocations[event.pointer] = event.position;

    if (_pointerLocations.length == 1 && _gestureMode != _GestureMode.pinch) {
      final start = _dragStart;
      if (start != null && (event.position - start).distance >= _dragSlop) {
        _cancelLongPressTimer();
      }
      if (_rangeSelecting && _dragAxis == _DragAxis.horizontal) {
        final day = _dayHitRegistry.dayAt(event.position);
        if (day != null) _onDayPointerEnter(day);
        return;
      }
      if (_isPanning && _panAxis != null && !_panBlocked) {
        final origin = _panOrigin ?? start;
        if (origin != null) {
          final delta = event.position - origin;
          _panOffset = _panAxis == _PanAxis.horizontal
              ? Offset(delta.dx, 0)
              : Offset(0, delta.dy);
          setState(() {});
        }
        return;
      }
      _resolveDragAxis(event.position);
      return;
    }

    if (_scrollLocked) return;

    if (_pointerLocations.length < 2 || _gestureMode != _GestureMode.pinch) return;

    final startSpan = _pinchStartDistance;
    if (startSpan == null || startSpan < _minPinchSpan) return;

    final span = _pointerSpan();
    final scale = span / startSpan;
    if ((scale - 1).abs() < _pinchScaleThreshold && !_pinchCommitted) return;

    _pinchCommitted = true;
    _markZoomUserTouched();
    _notifyZoomGesture();
    final viewport = _cachedViewport;
    final maxFit = viewport != null
        ? ScheduleViewportZoom.maxMonthsThatFit(viewport).toDouble()
        : ScheduleViewportZoom.maxMonths;
    final minZoom = ScheduleViewportZoom.minMonthsFor(widget.contentMode);
    setState(() {
      _monthsPerViewport = (_pinchBaseMonths / scale)
          .clamp(minZoom, math.min(ScheduleViewportZoom.maxMonths, maxFit));
      if (viewport != null) {
        final newMetrics = _layoutMetrics(viewport);
        _refocusAfterZoom(newMetrics, _gridCapacity(newMetrics));
      }
    });
  }

  void _handlePointerUp(PointerUpEvent event) {
    final viewport = _cachedViewport;
    final metrics = viewport != null ? _layoutMetrics(viewport) : null;
    final gridCapacity = metrics != null ? _gridCapacity(metrics) : 12;
    final wasPan = _isPanning && _panAxis != null && !_rangeSelecting;
    _pointerLocations.remove(event.pointer);
    if (_pointerLocations.isEmpty) {
      if (_longPressTriggered) {
        _resetGestureState();
        return;
      }
      if (wasPan && metrics != null && _gestureMode != _GestureMode.pinch) {
        _finishPan(metrics: metrics, gridCapacity: gridCapacity);
      } else if (_dragAxis == _DragAxis.horizontal &&
          _rangeSelecting &&
          _gestureMode != _GestureMode.pinch) {
        _finishRangeSelection();
      } else if (_dragAxis == _DragAxis.undecided &&
          _pendingRangeDay != null &&
          _gestureMode != _GestureMode.pinch) {
        widget.onDaySelected(_pendingRangeDay!, _pendingRangeDay!);
        if (!_isDayViewport()) {
          widget.onDayTap?.call(_pendingRangeDay!);
        }
      } else if (_rangeSelecting) {
        _cancelRangeSelection();
      } else if (_gestureMode == _GestureMode.pinch && _pinchCommitted) {
        unawaited(ScheduleZoomStorage.save(_monthsPerViewport, widget.contentMode));
        final m = viewport != null ? _layoutMetrics(viewport) : null;
        _notifyViewport(metrics: m);
      }
      _resetGestureState();
    } else if (_pointerLocations.length == 1 && _gestureMode == _GestureMode.pinch) {
      _gestureMode = _GestureMode.idle;
      _pinchStartDistance = null;
      _pinchCommitted = false;
      _panBlocked = false;
      final remaining = _pointerLocations.values.first;
      _panOrigin = remaining;
      _panAnchorMonthStart = _monthStartForYear(_displayYear);
      _panOffset = Offset.zero;
      _panAxis = null;
      _isPanning = true;
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _pointerLocations.remove(event.pointer);
    if (_pointerLocations.isEmpty) {
      _cancelRangeSelection();
      _resetGestureState();
    }
  }

  Widget _buildGridGestureLayer(Widget child) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: child,
    );
  }

  double _pointerSpan() {
    if (_pointerLocations.length < 2) return 0;
    final pts = _pointerLocations.values.toList(growable: false);
    return (pts[0] - pts[1]).distance;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final todayUtc = DateTime.utc(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _scrollLocked ? (_) => true : null,
      child: Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: _isPanning ? Clip.none : Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewportW = constraints.maxWidth;
            const headerBlock = 56.0;
            final viewportH = math.max(constraints.maxHeight - headerBlock, viewportW * 0.55);
            final viewport = Size(viewportW, viewportH);
            _cachedViewport = viewport;

            if (!_zoomBootstrapComplete && !_zoomUserTouched) {
              unawaited(_bootstrapZoomIfNeeded(viewport));
            }

            final metrics = _layoutMetrics(viewport);
            final gridCapacity = _gridCapacity(metrics);
            final gridHeight = metrics.visibleRows * metrics.cellHeight +
                (metrics.visibleRows - 1) * ScheduleViewportZoom.gap;
            _ensureMonthStartForYear(_displayYear, metrics, gridCapacity);

            return SizedBox(
              height: constraints.maxHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRect(
                    child: SizedBox(
                      height: 48,
                      child: Row(
                      children: [
                        IconButton(
                          onPressed: _displayYear > _minYear
                              ? () => _goToYear(_displayYear - 1)
                              : null,
                          icon: const Icon(Icons.chevron_left),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Предыдущий год',
                        ),
                        Expanded(
                          child: Text(
                            '$_displayYear',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _displayYear < _maxYear
                              ? () => _goToYear(_displayYear + 1)
                              : null,
                          icon: const Icon(Icons.chevron_right),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Следующий год',
                        ),
                        IconButton(
                          onPressed: _canZoomOut(viewport)
                              ? () => _stepZoom(zoomIn: false)
                              : null,
                          icon: const Icon(Icons.remove),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Уменьшить масштаб',
                        ),
                        IconButton(
                          onPressed:
                              _canZoomIn() ? () => _stepZoom(zoomIn: true) : null,
                          icon: const Icon(Icons.add),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Увеличить масштаб',
                        ),
                      ],
                    ),
                  ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SizedBox(
                      height: gridHeight,
                      child: ClipRect(
                        clipBehavior: Clip.none,
                        child: _buildGridGestureLayer(
                      CalendarDayHitScope(
                        registry: _dayHitRegistry,
                        child: metrics.dayOnlyViewport
                            ? Transform.translate(
                                offset: _dayPanPreview(),
                                child: _ScheduleMonthTile(
                                  year: widget.selectedDay.year,
                                  month: widget.selectedDay.month,
                                  cellSize: Size(viewportW, gridHeight),
                                  contentMode: widget.contentMode,
                                  itemsByDate: widget.itemsByDate,
                                  selectedDay: widget.selectedDay,
                                  rangeHighlightDayKeys: _activeRangeKeys,
                                  multiSelectMode: widget.multiSelectMode,
                                  todayUtc: todayUtc,
                                  onDayPointerDown: _onDayPointerDown,
                                  onDayPointerEnter: _onDayPointerEnter,
                                  onDayTap: _handleDayTap,
                                  onDayLongPress: widget.onDayLongPress,
                                  onAgendaItemTap: widget.onAgendaItemTap,
                                  onDayAgendaScrollEdges: _onDayAgendaScrollEdges,
                                  readOnly: widget.readOnly,
                                  dayOnly: true,
                                ),
                              )
                            : metrics.weekOnlyViewport
                            ? Transform.translate(
                                offset: _weekPanPreview(),
                                child: _ScheduleMonthTile(
                                year: widget.selectedDay.year,
                                month: widget.selectedDay.month,
                                cellSize: Size(viewportW, gridHeight),
                                contentMode: widget.contentMode,
                                itemsByDate: widget.itemsByDate,
                                selectedDay: widget.selectedDay,
                                rangeHighlightDayKeys: _activeRangeKeys,
                                multiSelectMode: widget.multiSelectMode,
                                todayUtc: todayUtc,
                                onDayPointerDown: _onDayPointerDown,
                                onDayPointerEnter: _onDayPointerEnter,
                                onDayTap: _handleDayTap,
                                onDayLongPress: widget.onDayLongPress,
                                onSeasonDayTap: widget.onSeasonDayTap,
                                onSeasonDayLongPress:
                                    _wrapSeasonDayLongPress(widget.onSeasonDayLongPress),
                                seasonEditingStageId: widget.seasonEditingStageId,
                                seasonEditingMonthYear: widget.seasonEditingMonthYear,
                                seasonEditingMonthMonth: widget.seasonEditingMonthMonth,
                                seasonClampStart: widget.seasonClampStart,
                                seasonClampEnd: widget.seasonClampEnd,
                                onSeasonStageChanged: widget.onSeasonStageChanged,
                                onSeasonStageCommit: widget.onSeasonStageCommit,
                                onSeasonSegmentEnterEdit:
                                    _wrapSeasonSegmentEnterEdit(widget.onSeasonSegmentEnterEdit),
                                onSeasonSegmentTap: widget.onSeasonSegmentTap,
                                onSegmentPointerDown: _onSeasonSegmentPointerDown,
                                readOnly: widget.readOnly,
                                showWeekdayHeaders: true,
                                weekOnly: true,
                                weekAnchor: widget.selectedDay,
                              ),
                              )
                            : PageView.builder(
                        controller: _yearPageController,
                        physics: const NeverScrollableScrollPhysics(),
                        onPageChanged: (index) {
                          _dayHitRegistry.clear();
                          _onYearPageChanged(index);
                        },
                        itemCount: _maxYear - _minYear + 1,
                        itemBuilder: (context, pageIndex) {
                          final year = _minYear + pageIndex;
                          _ensureMonthStartForYear(year, metrics, gridCapacity);
                          final preview = _panPreview(
                            metrics: metrics,
                            gridCapacity: gridCapacity,
                            year: year,
                          );
                          return Transform.translate(
                            offset: preview.translate,
                            child: _YearMonthsGrid(
                              year: year,
                              monthStartIndex: preview.displayStart,
                              gridCapacity: gridCapacity,
                              metrics: metrics,
                              seasonMonths: _seasonMonthsFor(year),
                              contentMode: widget.contentMode,
                              itemsByDate: widget.itemsByDate,
                              selectedDay: widget.selectedDay,
                              rangeHighlightDayKeys: _activeRangeKeys,
                              multiSelectMode: widget.multiSelectMode,
                              todayUtc: todayUtc,
                              onDayPointerDown: _onDayPointerDown,
                              onDayPointerEnter: _onDayPointerEnter,
                              onDayTap: _handleDayTap,
                              onDayLongPress: widget.onDayLongPress,
                              onSeasonDayTap: widget.onSeasonDayTap,
                              onSeasonDayLongPress:
                                  _wrapSeasonDayLongPress(widget.onSeasonDayLongPress),
                              seasonEditingStageId: widget.seasonEditingStageId,
                              seasonEditingMonthYear: widget.seasonEditingMonthYear,
                              seasonEditingMonthMonth: widget.seasonEditingMonthMonth,
                              seasonClampStart: widget.seasonClampStart,
                              seasonClampEnd: widget.seasonClampEnd,
                              onSeasonStageChanged: widget.onSeasonStageChanged,
                              onSeasonStageCommit: widget.onSeasonStageCommit,
                              onSeasonSegmentEnterEdit:
                                  _wrapSeasonSegmentEnterEdit(widget.onSeasonSegmentEnterEdit),
                              onSeasonSegmentTap: widget.onSeasonSegmentTap,
                              onSegmentPointerDown: _onSeasonSegmentPointerDown,
                              readOnly: widget.readOnly,
                              showWeekdayHeaders: metrics.singleMonthViewport ||
              _effectiveMonthsPerViewport.round() == 1,
                            ),
                          );
                        },
                      ),
                    ),
                      ),
                    ),
                  ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
    );
  }
}

class _YearMonthsGrid extends StatelessWidget {
  const _YearMonthsGrid({
    required this.year,
    required this.monthStartIndex,
    required this.gridCapacity,
    required this.metrics,
    required this.seasonMonths,
    required this.contentMode,
    required this.itemsByDate,
    required this.selectedDay,
    required this.rangeHighlightDayKeys,
    this.multiSelectMode = false,
    required this.todayUtc,
    required this.onDayPointerDown,
    required this.onDayPointerEnter,
    required this.onDayTap,
    this.onDayLongPress,
    this.onSeasonDayTap,
    this.onSeasonDayLongPress,
    this.seasonEditingStageId,
    this.seasonEditingMonthYear,
    this.seasonEditingMonthMonth,
    this.seasonClampStart,
    this.seasonClampEnd,
    this.onSeasonStageChanged,
    this.onSeasonStageCommit,
    this.onSeasonSegmentEnterEdit,
    this.onSeasonSegmentTap,
    this.onSegmentPointerDown,
    this.readOnly = false,
    this.showWeekdayHeaders = false,
  });

  final int year;
  final int monthStartIndex;
  final int gridCapacity;
  final ScheduleGridMetrics metrics;
  final Map<int, MonthRowLayout> seasonMonths;
  final CalendarContentMode contentMode;
  final Map<String, List<Map<String, dynamic>>> itemsByDate;
  final DateTime selectedDay;
  final Set<String> rangeHighlightDayKeys;
  final bool multiSelectMode;
  final DateTime todayUtc;
  final void Function(DateTime day) onDayPointerDown;
  final void Function(DateTime day) onDayPointerEnter;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime day)? onDayLongPress;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onSeasonDayTap;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onSeasonDayLongPress;
  final int? seasonEditingStageId;
  final int? seasonEditingMonthYear;
  final int? seasonEditingMonthMonth;
  final DateTime? seasonClampStart;
  final DateTime? seasonClampEnd;
  final void Function(int stageId, Map<String, dynamic> patch)? onSeasonStageChanged;
  final Future<void> Function(Map<String, dynamic> stage)? onSeasonStageCommit;
  final void Function(StageMonthSegment segment)? onSeasonSegmentEnterEdit;
  final void Function(StageMonthSegment segment)? onSeasonSegmentTap;
  final void Function(StageMonthSegment segment)? onSegmentPointerDown;
  final bool readOnly;
  final bool showWeekdayHeaders;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: metrics.columns,
        mainAxisExtent: metrics.cellHeight,
        crossAxisSpacing: ScheduleViewportZoom.gap,
        mainAxisSpacing: ScheduleViewportZoom.gap,
      ),
      itemCount: gridCapacity,
      itemBuilder: (context, index) {
        final month = monthStartIndex + index + 1;
        if (month < 1 || month > 12) {
          return const SizedBox.shrink();
        }
        return _ScheduleMonthTile(
          year: year,
          month: month,
          cellSize: Size(metrics.cellWidth, metrics.cellHeight),
          contentMode: contentMode,
          itemsByDate: itemsByDate,
          monthRow: seasonMonths[month],
          selectedDay: selectedDay,
          rangeHighlightDayKeys: rangeHighlightDayKeys,
          multiSelectMode: multiSelectMode,
          todayUtc: todayUtc,
          onDayPointerDown: onDayPointerDown,
          onDayPointerEnter: onDayPointerEnter,
          onDayTap: onDayTap,
          onDayLongPress: onDayLongPress,
          onSeasonDayTap: onSeasonDayTap,
          onSeasonDayLongPress: onSeasonDayLongPress,
          seasonEditingStageId: seasonEditingStageId,
          seasonEditingMonthYear: seasonEditingMonthYear,
          seasonEditingMonthMonth: seasonEditingMonthMonth,
          seasonClampStart: seasonClampStart,
          seasonClampEnd: seasonClampEnd,
          onSeasonStageChanged: onSeasonStageChanged,
          onSeasonStageCommit: onSeasonStageCommit,
          onSeasonSegmentEnterEdit: onSeasonSegmentEnterEdit,
          onSeasonSegmentTap: onSeasonSegmentTap,
          onSegmentPointerDown: onSegmentPointerDown,
          readOnly: readOnly,
          showWeekdayHeaders: showWeekdayHeaders,
          singleMonthLayout: metrics.singleMonthViewport,
        );
      },
    );
  }
}

class _ScheduleMonthTile extends StatelessWidget {
  const _ScheduleMonthTile({
    required this.year,
    required this.month,
    required this.cellSize,
    required this.contentMode,
    required this.itemsByDate,
    required this.selectedDay,
    required this.rangeHighlightDayKeys,
    this.multiSelectMode = false,
    required this.todayUtc,
    required this.onDayPointerDown,
    required this.onDayPointerEnter,
    required this.onDayTap,
    this.monthRow,
    this.onDayLongPress,
    this.onSeasonDayTap,
    this.onSeasonDayLongPress,
    this.seasonEditingStageId,
    this.seasonEditingMonthYear,
    this.seasonEditingMonthMonth,
    this.seasonClampStart,
    this.seasonClampEnd,
    this.onSeasonStageChanged,
    this.onSeasonStageCommit,
    this.onSeasonSegmentEnterEdit,
    this.onSeasonSegmentTap,
    this.onSegmentPointerDown,
    this.readOnly = false,
    this.showWeekdayHeaders = false,
    this.weekOnly = false,
    this.dayOnly = false,
    this.singleMonthLayout = false,
    this.weekAnchor,
    this.onAgendaItemTap,
    this.onDayAgendaScrollEdges,
  });

  final int year;
  final int month;
  final Size cellSize;
  final CalendarContentMode contentMode;
  final Map<String, List<Map<String, dynamic>>> itemsByDate;
  final MonthRowLayout? monthRow;
  final DateTime selectedDay;
  final Set<String> rangeHighlightDayKeys;
  final bool multiSelectMode;
  final DateTime todayUtc;
  final void Function(DateTime day) onDayPointerDown;
  final void Function(DateTime day) onDayPointerEnter;
  final void Function(DateTime day) onDayTap;
  final void Function(DateTime day)? onDayLongPress;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onSeasonDayTap;
  final void Function(DateTime day, List<StageMonthSegment> daySegments)? onSeasonDayLongPress;
  final int? seasonEditingStageId;
  final int? seasonEditingMonthYear;
  final int? seasonEditingMonthMonth;
  final DateTime? seasonClampStart;
  final DateTime? seasonClampEnd;
  final void Function(int stageId, Map<String, dynamic> patch)? onSeasonStageChanged;
  final Future<void> Function(Map<String, dynamic> stage)? onSeasonStageCommit;
  final void Function(StageMonthSegment segment)? onSeasonSegmentEnterEdit;
  final void Function(StageMonthSegment segment)? onSeasonSegmentTap;
  final void Function(StageMonthSegment segment)? onSegmentPointerDown;
  final bool readOnly;
  final bool showWeekdayHeaders;
  final bool weekOnly;
  final bool dayOnly;
  final bool singleMonthLayout;
  final DateTime? weekAnchor;
  final void Function(DateTime day, Map<String, dynamic> item)? onAgendaItemTap;
  final void Function({required bool atTop, required bool atBottom})?
      onDayAgendaScrollEdges;

  bool get _detailed => cellSize.height >= 72 && cellSize.width >= 64;

  List<DateTime> get _weekDays {
    final anchor = weekAnchor ?? selectedDay;
    final offset = anchor.weekday - DateTime.monday;
    final weekStart = _dateOnly(anchor.subtract(Duration(days: offset < 0 ? 6 : offset)));
    return List.generate(7, (i) => weekStart.add(Duration(days: i)));
  }

  List<DateTime> get _gridDays {
    if (weekOnly) return _weekDays;
    final first = DateTime(year, month, 1);
    final last = DateTime(year, month + 1, 0);
    final startOffset = first.weekday - DateTime.monday;
    final gridStart = first.subtract(Duration(days: startOffset < 0 ? 6 : startOffset));
    final days = <DateTime>[];
    var cursor = gridStart;
    while (cursor.isBefore(last) ||
        cursor.month == month ||
        days.length % 7 != 0) {
      days.add(_dateOnly(cursor));
      cursor = cursor.add(const Duration(days: 1));
      if (days.length >= 42) break;
    }
    while (days.length < 42) {
      days.add(_dateOnly(cursor));
      cursor = cursor.add(const Duration(days: 1));
    }
    return days;
  }

  String get _monthLabel {
    if (weekOnly) {
      final days = _weekDays;
      final start = days.first;
      final end = days.last;
      if (start.month == end.month && start.year == end.year) {
        return '${DateFormat('d', 'ru').format(start)}–${DateFormat('d MMMM yyyy', 'ru').format(end)}';
      }
      if (start.year == end.year) {
        return '${DateFormat('d MMM', 'ru').format(start)} – ${DateFormat('d MMM yyyy', 'ru').format(end)}';
      }
      return '${DateFormat('d MMM yyyy', 'ru').format(start)} – ${DateFormat('d MMM yyyy', 'ru').format(end)}';
    }
    final date = DateTime(year, month, 1);
    if (cellSize.height < 72) {
      return DateFormat('LLL', 'ru').format(date);
    }
    if (cellSize.height < 110) {
      return DateFormat('LLL yy', 'ru').format(date);
    }
    return DateFormat('LLLL', 'ru').format(date);
  }

  List<StageMonthSegment> get _seasonSegments =>
      monthRow?.placements.map((p) => p.segment).toList() ?? const [];

  TextStyle _monthHeaderStyle(BuildContext context, ColorScheme cs) {
    final micro = cellSize.height < 72 || cellSize.width < 64;
    final tiny = cellSize.height < 100 || cellSize.width < 90;
    final compact = cellSize.height < 140 || cellSize.width < 120;
    final fontSize = micro ? 9.0 : (tiny ? 10.0 : (compact ? 12.0 : 14.0));
    return (Theme.of(context).textTheme.labelMedium ??
            Theme.of(context).textTheme.bodySmall!)
        .copyWith(
          fontWeight: FontWeight.w700,
          fontSize: fontSize,
          height: 1.1,
          color: cs.onSurface,
        );
  }

  @override
  Widget build(BuildContext context) {
    if (contentMode == CalendarContentMode.stages && monthRow != null) {
      return SeasonMiniMonthCalendar(
        month: monthRow!.month,
        segments: _seasonSegments,
        cellSize: cellSize,
        selectedDay: selectedDay,
        rangeHighlightDayKeys: rangeHighlightDayKeys,
        onDayPointerDown: onDayPointerDown,
        onDayPointerEnter: onDayPointerEnter,
        onDayTap: onSeasonDayTap,
        onDayLongPress: readOnly ? null : onSeasonDayLongPress,
        editingStageId: seasonEditingStageId,
        editingMonthYear: seasonEditingMonthYear,
        editingMonthMonth: seasonEditingMonthMonth,
        seasonStart: seasonClampStart,
        seasonEnd: seasonClampEnd,
        onStageChanged: onSeasonStageChanged,
        onStageCommit: onSeasonStageCommit,
        onSegmentEnterEdit: onSeasonSegmentEnterEdit,
        onSegmentTap: onSeasonSegmentTap,
        onSegmentPointerDown: onSegmentPointerDown,
        showWeekdayHeaders: showWeekdayHeaders,
      );
    }

    final cs = Theme.of(context).colorScheme;
    final weekdayLabelW = weekOnly && showWeekdayHeaders ? 28.0 : 0.0;
    final weekdayH = weekOnly
        ? 0.0
        : (showWeekdayHeaders && cellSize.height >= 88 ? 18.0 : 0.0);
    final headerH = cellSize.height < 56
        ? 12.0
        : (cellSize.height < 72 ? 14.0 : 24.0);
    final gridH = math.max(0.0, cellSize.height - headerH - weekdayH - 2);
    final visibleDays = weekOnly ? _weekDays : _gridDays;

    if (dayOnly) {
      return _buildDayAgendaView(context: context, cs: cs);
    }

    if (weekOnly) {
      return _buildWeekVerticalView(
        context: context,
        cs: cs,
        headerH: headerH,
        gridH: gridH,
        weekdayLabelW: weekdayLabelW,
        visibleDays: visibleDays,
      );
    }

    final gridRows = 6;
    final dayH = gridH / gridRows;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: headerH,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _monthLabel,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: _monthHeaderStyle(context, cs),
                ),
              ),
            ),
          ),
          if (showWeekdayHeaders)
            CalendarWeekdayHeaderRow(height: weekdayH, gap: 1),
          SizedBox(
            height: gridH,
            child: ClipRect(
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisExtent: dayH,
                  crossAxisSpacing: 1,
                  mainAxisSpacing: 1,
                ),
                itemCount: visibleDays.length,
                itemBuilder: (context, index) {
                  final day = visibleDays[index];
                  if (day.month != month) {
                    return const SizedBox.shrink();
                  }
                  final key = ScheduleCalendarPanel.dateKey(day);
                  final items = itemsByDate[key] ?? const [];
                  return CalendarDayPointerCell(
                    day: day,
                    onPointerDown: () => onDayPointerDown(day),
                    onPointerEnter: () => onDayPointerEnter(day),
                    child: _detailed
                        ? _MonthDayCell(
                            day: day,
                            selected:
                                _isSameDay(day, selectedDay) && !multiSelectMode,
                            rangeHighlighted: rangeHighlightDayKeys.contains(key),
                            today: _isSameDay(day, DateTime.now()),
                            items: items,
                            todayUtc: todayUtc,
                            singleMonthLayout: singleMonthLayout,
                          )
                        : _CompactDayCell(
                            day: day.day,
                            items: items,
                            selected:
                                _isSameDay(day, selectedDay) && !multiSelectMode,
                            rangeHighlighted:
                                rangeHighlightDayKeys.contains(key),
                            today: _isSameDay(day, DateTime.now()),
                          ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const _weekdayLabels = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

  String _weekdayLabel(DateTime day) {
    final offset = day.weekday - DateTime.monday;
    return _weekdayLabels[offset < 0 ? 6 : offset];
  }

  Widget _buildDayAgendaView({
    required BuildContext context,
    required ColorScheme cs,
  }) {
    final day = selectedDay;
    final key = ScheduleCalendarPanel.dateKey(day);
    final items = itemsByDate[key] ?? const [];
    final dateLabel = DateFormat('EEEE, d MMMM yyyy', 'ru').format(day);
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Text(
              dateLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.primary,
              ),
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.45)),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      'Нет событий',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollUpdateNotification ||
                          notification is ScrollEndNotification ||
                          notification is ScrollMetricsNotification) {
                        final metrics = notification.metrics;
                        onDayAgendaScrollEdges?.call(
                          atTop: metrics.pixels <= metrics.minScrollExtent + 0.5,
                          atBottom:
                              metrics.pixels >= metrics.maxScrollExtent - 0.5,
                        );
                      }
                      return false;
                    },
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return _DayAgendaWorkoutCard(
                          item: item,
                          onTap: onAgendaItemTap != null
                              ? () => onAgendaItemTap!(day, item)
                              : () => onDayTap(day),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekVerticalView({
    required BuildContext context,
    required ColorScheme cs,
    required double headerH,
    required double gridH,
    required double weekdayLabelW,
    required List<DateTime> visibleDays,
  }) {
    final dayH = gridH / visibleDays.length;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
          fontSize: 11,
        );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: headerH,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _monthLabel,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: _monthHeaderStyle(context, cs),
                ),
              ),
            ),
          ),
          SizedBox(
            height: gridH,
            child: Column(
              children: [
                for (final day in visibleDays)
                  SizedBox(
                    height: dayH,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (weekdayLabelW > 0)
                          SizedBox(
                            width: weekdayLabelW,
                            child: Center(
                              child: Text(
                                _weekdayLabel(day),
                                style: labelStyle,
                              ),
                            ),
                          ),
                        Expanded(
                          child: CalendarDayPointerCell(
                            day: day,
                            onPointerDown: () => onDayPointerDown(day),
                            onPointerEnter: () => onDayPointerEnter(day),
                            child: _detailed
                                ? _MonthDayCell(
                                    day: day,
                                    selected:
                                        _isSameDay(day, selectedDay) && !multiSelectMode,
                                    rangeHighlighted: rangeHighlightDayKeys
                                        .contains(ScheduleCalendarPanel.dateKey(day)),
                                    today: _isSameDay(day, DateTime.now()),
                                    items: itemsByDate[
                                            ScheduleCalendarPanel.dateKey(day)] ??
                                        const [],
                                    todayUtc: todayUtc,
                                  )
                                : _CompactDayCell(
                                    day: day.day,
                                    items: itemsByDate[
                                            ScheduleCalendarPanel.dateKey(day)] ??
                                        const [],
                                    selected:
                                        _isSameDay(day, selectedDay) && !multiSelectMode,
                                    rangeHighlighted: rangeHighlightDayKeys.contains(
                                      ScheduleCalendarPanel.dateKey(day),
                                    ),
                                    today: _isSameDay(day, DateTime.now()),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactDayCell extends StatelessWidget {
  const _CompactDayCell({
    required this.day,
    required this.items,
    required this.selected,
    required this.rangeHighlighted,
    required this.today,
  });

  final int day;
  final List<Map<String, dynamic>> items;
  final bool selected;
  final bool rangeHighlighted;
  final bool today;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasEvents = items.isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        final w = constraints.maxWidth;
        final showText = _monthDayShowsEventText(height: h, width: w);
        final dayColor = selected
            ? cs.primary
            : today
                ? cs.primary
                : cs.onSurface;

        if (hasEvents) {
          final fillColor =
              _monthEventAccent(items.first).withValues(alpha: 0.78);
          return ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: items.length == 1
                      ? _MonthColorBlock(
                          item: items.first,
                          borderRadius: 0,
                          opacity: 0.78,
                        )
                      : _MonthMultiColorBlock(items: items, opacity: 0.78),
                ),
                if (rangeHighlighted)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: cs.secondary,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  )
                else if (selected)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: cs.primary,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  )
                else if (today)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.65),
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                Center(
                  child: _DayNumberOnFill(
                    day: day,
                    selected: selected,
                    today: today,
                    maxHeight: h,
                    fillColor: items.length == 1 ? fillColor : null,
                  ),
                ),
              ],
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: rangeHighlighted
                  ? Border.all(color: cs.secondary, width: 1.5)
                  : null,
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '$day',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: showText ? 9 : 8,
                        fontWeight: FontWeight.w600,
                        color: dayColor,
                        height: 1,
                      ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MonthDayCell extends StatelessWidget {
  const _MonthDayCell({
    required this.day,
    required this.selected,
    required this.rangeHighlighted,
    required this.today,
    required this.items,
    required this.todayUtc,
    this.singleMonthLayout = false,
  });

  final DateTime day;
  final bool selected;
  final bool rangeHighlighted;
  final bool today;
  final List<Map<String, dynamic>> items;
  final DateTime todayUtc;
  final bool singleMonthLayout;

  static const _previewMax = 2;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final count = items.length;
    final singleTitleFill = count == 1;
    final dualTitleFill = count == 2;

    Color borderColor = Colors.transparent;
    Color? fillColor;
    if (rangeHighlighted) {
      borderColor = cs.secondary;
      fillColor = cs.secondary.withValues(alpha: 0.14);
    } else if (selected) {
      borderColor = cs.primary;
      fillColor = cs.primary.withValues(alpha: 0.07);
    } else if (today) {
      borderColor = cs.primary.withValues(alpha: 0.3);
      fillColor = cs.primary.withValues(alpha: 0.03);
    } else if (items.isNotEmpty && !singleTitleFill) {
      fillColor = cs.surfaceContainerHighest.withValues(alpha: 0.3);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        final w = constraints.maxWidth;
        if (singleMonthLayout) {
          return _buildSingleMonthLayout(
            context,
            cs: cs,
            height: h,
            width: w,
            borderColor: borderColor,
            fillColor: fillColor,
          );
        }
        final showText = _monthDayShowsEventText(height: h, width: w);
        final density = _dayCellDensity(h);
        final dayHeaderH = density == _DayCellDensity.micro
            ? math.min(h * 0.42, 12.0)
            : math.min(h * 0.38, 22.0);

        if (count > 0 && (h < 50 || !showText)) {
          final primaryFill = _monthEventAccent(items.first).withValues(alpha: 0.78);
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: count == 1
                      ? _MonthColorBlock(
                          item: items.first,
                          borderRadius: 0,
                          opacity: 0.78,
                        )
                      : _MonthMultiColorBlock(items: items, opacity: 0.78),
                ),
                if (rangeHighlighted)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.secondary, width: 1.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  )
                else if (selected)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.primary, width: 1.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  )
                else if (today)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.65),
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                Center(
                  child: _DayNumberOnFill(
                    day: day.day,
                    selected: selected,
                    today: today,
                    maxHeight: h,
                    fillColor: count == 1 ? primaryFill : null,
                  ),
                ),
              ],
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            padding: const EdgeInsets.fromLTRB(1, 2, 1, 1),
            decoration: BoxDecoration(
              color: singleTitleFill ? null : fillColor,
              border: Border.all(
                color: borderColor,
                width: selected || rangeHighlighted ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: _DayNumber(
                    day: day.day,
                    selected: selected,
                    today: today,
                    maxHeight: dayHeaderH,
                  ),
                ),
                    if (singleTitleFill) ...[
                      const SizedBox(height: 1),
                      Expanded(
                        child: _MonthTitleFill(
                          item: items.first,
                          todayUtc: todayUtc,
                          showText: showText,
                        ),
                      ),
                    ] else if (dualTitleFill) ...[
                      const SizedBox(height: 1),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 1),
                                child: _MonthTitleFill(
                                  item: items[0],
                                  todayUtc: todayUtc,
                                  showText: showText,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _MonthTitleFill(
                                item: items[1],
                                todayUtc: todayUtc,
                                showText: showText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else if (count > 2)
                      ..._buildManyEventsPreview(context, cs, showText: showText),
                  ],
                ),
              ),
            );
      },
    );
  }

  Widget _buildSingleMonthLayout(
    BuildContext context, {
    required ColorScheme cs,
    required double height,
    required double width,
    required Color borderColor,
    required Color? fillColor,
  }) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.fromLTRB(3, 2, 3, 2),
        decoration: BoxDecoration(
          color: fillColor,
          border: Border.all(
            color: borderColor,
            width: selected || rangeHighlighted ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: _DayNumber(
                day: day.day,
                selected: selected,
                today: today,
                maxHeight: 18,
              ),
            ),
            if (items.isEmpty)
              const Spacer()
            else
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  physics: const ClampingScrollPhysics(),
                  children: [
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 3,
                              height: 24,
                              margin: const EdgeInsets.only(top: 1, right: 4),
                              decoration: BoxDecoration(
                                color: _monthEventAccent(item),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _singleMonthItemLine(item),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 9,
                                  height: 1.15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _singleMonthItemLine(Map<String, dynamic> item) {
    final title = AgendaUtils.cellTitle(item);
    final display = title.isNotEmpty
        ? title
        : (item['kind'] == 'workout' ? 'Тренировка' : 'Событие');
    final time = AgendaUtils.cellTime(item);
    if (time != null) return '$time $display';
    return display;
  }

  List<Widget> _buildManyEventsPreview(
    BuildContext context,
    ColorScheme cs, {
    required bool showText,
  }) {
    final allDayItems = items
        .where(
          (i) =>
              i['all_day'] == true ||
              i['kind'] == 'vacation' ||
              i['kind'] == 'sick',
        )
        .toList(growable: false);
    final timedItems = items
        .where(
          (i) =>
              i['all_day'] != true &&
              i['kind'] != 'vacation' &&
              i['kind'] != 'sick',
        )
        .toList(growable: false);

    final allDayPreview = allDayItems.take(_previewMax).toList();
    final timedSlots = (_previewMax - allDayPreview.length).clamp(0, _previewMax);
    final timedPreview = timedItems.take(timedSlots).toList();
    final overflow = items.length - allDayPreview.length - timedPreview.length;

    if (allDayPreview.isEmpty && timedPreview.isEmpty) {
      return const [];
    }

    return [
      const SizedBox(height: 2),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in allDayPreview)
              Expanded(
                flex: 2,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: _MonthTitleBlock(
                    item: item,
                    todayUtc: todayUtc,
                    showText: showText,
                  ),
                ),
              ),
            for (final item in timedPreview)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: _MonthEventChip(
                    item: item,
                    todayUtc: todayUtc,
                    showText: showText,
                  ),
                ),
              ),
            if (showText && overflow > 0)
              Text(
                '+$overflow',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 8,
                      height: 1,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
          ],
        ),
      ),
    ];
  }
}

String _monthItemTitle(Map<String, dynamic> item) {
  final title = AgendaUtils.cellTitle(item);
  if (title.isNotEmpty) return title;
  if (item['kind'] == 'workout') return 'Тренировка';
  return 'Событие';
}

class _MonthColorBlock extends StatelessWidget {
  const _MonthColorBlock({
    required this.item,
    this.borderRadius = 4,
    this.opacity = 0.55,
  });

  final Map<String, dynamic> item;
  final double borderRadius;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final accent = _monthEventAccent(item);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: opacity),
        borderRadius: borderRadius > 0 ? BorderRadius.circular(borderRadius) : null,
      ),
    );
  }
}

class _MonthMultiColorBlock extends StatelessWidget {
  const _MonthMultiColorBlock({
    required this.items,
    this.opacity = 0.55,
  });

  final List<Map<String, dynamic>> items;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final preview = items.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < preview.length; i++)
          Expanded(
            child: _MonthColorBlock(
              item: preview[i],
              borderRadius: 0,
              opacity: opacity,
            ),
          ),
      ],
    );
  }
}

class _DayNumberOnFill extends StatelessWidget {
  const _DayNumberOnFill({
    required this.day,
    required this.selected,
    required this.today,
    required this.maxHeight,
    this.fillColor,
  });

  final int day;
  final bool selected;
  final bool today;
  final double maxHeight;
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = math.min(22.0, maxHeight * 0.72).clamp(8.0, 22.0);
    final fontSize = (size * 0.58).clamp(6.0, 12.0);
    final onFill = fillColor != null ? _contrastTextOn(fillColor!) : null;

    if (selected) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.primary,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$day',
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      );
    }

    final textStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1,
      color: today
          ? cs.primary
          : (onFill ?? Theme.of(context).colorScheme.onSurface),
      shadows: onFill != null && !today
          ? const [
              Shadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 0.5)),
            ]
          : null,
    );

    if (today) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.82),
          border: Border.all(color: cs.primary, width: 1),
        ),
        child: Text('$day', style: textStyle),
      );
    }

    return Text('$day', style: textStyle);
  }
}

class _MonthTitleFill extends StatelessWidget {
  const _MonthTitleFill({
    required this.item,
    required this.todayUtc,
    this.showText = true,
  });

  final Map<String, dynamic> item;
  final DateTime todayUtc;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    final accent = _monthEventAccent(item);

    return Container(
      width: double.infinity,
      padding: showText ? const EdgeInsets.symmetric(horizontal: 3, vertical: 2) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: showText ? 0.38 : 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: showText ? Alignment.center : null,
      child: showText
          ? Text(
              _monthItemTitle(item),
              maxLines: 3,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 8,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
            )
          : null,
    );
  }
}

class _MonthTitleBlock extends StatelessWidget {
  const _MonthTitleBlock({
    required this.item,
    required this.todayUtc,
    this.showText = true,
  });

  final Map<String, dynamic> item;
  final DateTime todayUtc;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    final accent = _monthEventAccent(item);

    return Container(
      width: double.infinity,
      padding: showText ? const EdgeInsets.symmetric(horizontal: 3, vertical: 2) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: showText ? 0.32 : 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: showText ? Alignment.centerLeft : null,
      child: showText
          ? Text(
              _monthItemTitle(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 8,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
            )
          : null,
    );
  }
}

Color _monthEventAccent(Map<String, dynamic> item) => scheduleItemBlockColor(item);

class _DayNumber extends StatelessWidget {
  const _DayNumber({
    required this.day,
    required this.selected,
    required this.today,
    this.maxHeight = 22,
  });

  final int day;
  final bool selected;
  final bool today;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = math.min(22.0, maxHeight).clamp(8.0, 22.0);
    final fontSize = (size * 0.55).clamp(6.0, 12.0);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: fontSize,
          height: 1,
        );

    if (selected) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.primary,
          shape: BoxShape.circle,
        ),
        child: Text('$day', style: style?.copyWith(color: Colors.white)),
      );
    }

    if (today) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: cs.primary, width: 1.0),
        ),
        child: Text('$day', style: style?.copyWith(color: cs.primary)),
      );
    }

    return SizedBox(
      height: size,
      child: Center(child: Text('$day', style: style)),
    );
  }
}

class _MonthEventChip extends StatelessWidget {
  const _MonthEventChip({
    required this.item,
    required this.todayUtc,
    this.showText = true,
  });

  final Map<String, dynamic> item;
  final DateTime todayUtc;
  final bool showText;

  String get _label {
    final time = AgendaUtils.cellTime(item);
    if (time != null) return time;
    if (item['all_day'] == true) return '∞';
    final title = AgendaUtils.cellTitle(item);
    return title.isEmpty ? '•' : title.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accentColor(context);

    if (!showText) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(3),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final chipH = math.min(13.0, constraints.maxHeight).clamp(4.0, 13.0);
        return Container(
          height: chipH,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 2, right: 1),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            children: [
              Container(
                width: 2,
                height: math.max(3, chipH - 4),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  _label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: 8,
                        height: 1,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _accentColor(BuildContext context) => _monthEventAccent(item);
}

class _DayAgendaWorkoutCard extends StatelessWidget {
  const _DayAgendaWorkoutCard({
    required this.item,
    this.onTap,
  });

  final Map<String, dynamic> item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = _monthEventAccent(item);
    final title = AgendaUtils.cellTitle(item);
    final displayTitle = title.isNotEmpty
        ? title
        : (item['kind'] == 'workout' ? 'Тренировка' : 'Событие');
    final time = AgendaUtils.cellTime(item);
    final duration = AgendaUtils.durationMinutes(item);
    final exercises = (item['exercises'] as List?) ?? const [];
    final kind = item['kind']?.toString();

    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 4,
                    height: 40,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayTitle,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          time != null ? '$time · $duration мин' : '$duration мин',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (kind == 'workout' && exercises.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final raw in exercises)
                  Padding(
                    padding: const EdgeInsets.only(left: 14, bottom: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '· ',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            (raw as Map<String, dynamic>)['exercise']?['name']
                                    ?.toString() ??
                                'Упражнение',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

typedef ScheduleMonthCalendar = ScheduleCalendarPanel;