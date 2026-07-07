import 'package:flutter/material.dart';

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Реестр глобальных границ ячеек дней для drag-выделения на touch.
class CalendarDayHitRegistry {
  final Map<DateTime, Rect> _rects = {};

  void update(DateTime day, Rect globalRect) {
    _rects[_dateOnly(day)] = globalRect;
  }

  void clear() => _rects.clear();

  DateTime? dayAt(Offset globalPosition) {
    DateTime? bestDay;
    var bestArea = double.infinity;
    for (final entry in _rects.entries) {
      final rect = entry.value;
      if (!rect.contains(globalPosition)) continue;
      final area = rect.width * rect.height;
      if (area < bestArea) {
        bestArea = area;
        bestDay = entry.key;
      }
    }
    return bestDay;
  }
}

class CalendarDayHitScope extends InheritedWidget {
  const CalendarDayHitScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final CalendarDayHitRegistry registry;

  static CalendarDayHitRegistry? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<CalendarDayHitScope>()
        ?.registry;
  }

  @override
  bool updateShouldNotify(covariant CalendarDayHitScope oldWidget) => false;
}

/// Ячейка дня: tap/down, hover (desktop) и регистрация bounds для touch-drag.
class CalendarDayPointerCell extends StatefulWidget {
  const CalendarDayPointerCell({
    super.key,
    required this.day,
    required this.onPointerDown,
    required this.onPointerEnter,
    required this.child,
  });

  final DateTime day;
  final VoidCallback onPointerDown;
  final VoidCallback onPointerEnter;
  final Widget child;

  @override
  State<CalendarDayPointerCell> createState() => _CalendarDayPointerCellState();
}

class _CalendarDayPointerCellState extends State<CalendarDayPointerCell> {
  void _syncBounds() {
    final registry = CalendarDayHitScope.maybeOf(context);
    if (registry == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    registry.update(widget.day, origin & box.size);
  }

  @override
  void didUpdateWidget(covariant CalendarDayPointerCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBounds();
    });
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBounds();
    });
    return MouseRegion(
      onEnter: (_) => widget.onPointerEnter(),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => widget.onPointerDown(),
        child: widget.child,
      ),
    );
  }
}

/// Строка заголовков дней недели (пн–вс) над сеткой календаря.
class CalendarWeekdayHeaderRow extends StatelessWidget {
  const CalendarWeekdayHeaderRow({
    super.key,
    this.height = 18,
    this.gap = 0,
  });

  final double height;
  final double gap;

  static const _labels = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontSize: height < 16 ? 9 : null,
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW =
            (constraints.maxWidth - gap * (_labels.length - 1)) / _labels.length;
        return SizedBox(
          height: height,
          child: Row(
            children: [
              for (var i = 0; i < _labels.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                SizedBox(
                  width: cellW,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(_labels[i], style: style, maxLines: 1),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
