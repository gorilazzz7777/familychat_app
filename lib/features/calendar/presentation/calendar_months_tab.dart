import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/app_providers.dart';
import '../data/calendar_agenda_utils.dart';
import 'calendar_event_edit_screen.dart';
import 'widgets/family_calendar_panel.dart';

class CalendarMonthsTab extends ConsumerStatefulWidget {
  const CalendarMonthsTab({super.key, required this.reloadToken});

  final int reloadToken;

  @override
  ConsumerState<CalendarMonthsTab> createState() => _CalendarMonthsTabState();
}

class _CalendarMonthsTabState extends ConsumerState<CalendarMonthsTab> {
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  int _displayYear = DateTime.now().year;
  int _loadedAgendaYear = DateTime.now().year;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  bool _dayOnlyViewport = false;
  final ValueNotifier<bool> _dayGestureCapture = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _loadAgendaForYear(year: _displayYear);
  }

  @override
  void didUpdateWidget(covariant CalendarMonthsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      _loadAgendaForYear(year: _loadedAgendaYear, silent: _items.isNotEmpty);
    }
  }

  @override
  void dispose() {
    _dayGestureCapture.dispose();
    super.dispose();
  }

  Map<String, List<Map<String, dynamic>>> get _byDate =>
      AgendaUtils.groupByDisplayDate(_items);

  Future<void> _loadAgendaForYear({required int year, bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await ref.read(familychatRepositoryProvider).calendarAgenda(year: year);
      if (!mounted) return;
      setState(() {
        _items = (data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _loadedAgendaYear = year;
        _error = null;
      });
    } catch (e) {
      if (mounted && !silent) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    await _loadAgendaForYear(year: _loadedAgendaYear, silent: _items.isNotEmpty);
  }

  void _showDayPanel(DateTime day) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _DayEventsSheet(
        day: day,
        events: _byDate[AgendaUtils.dateKey(day)] ?? const [],
        onEventTap: (item) {
          Navigator.pop(ctx);
          unawaited(_openAgendaItem(day, item));
        },
        onCreate: () {
          Navigator.pop(ctx);
          unawaited(_openCreateEvent(day));
        },
      ),
    );
  }

  void _onAgendaDayTap(DateTime day) {
    if (_dayOnlyViewport) return;
    _showDayPanel(day);
  }

  Future<void> _openCreateEvent(DateTime day) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CalendarEventEditScreen(initialDate: day),
      ),
    );
    if (changed == true) await _refresh();
  }

  Future<void> _openAgendaItem(DateTime day, Map<String, dynamic> item) async {
    if (item['editable'] != true) {
      final title = item['title']?.toString() ?? 'Событие';
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(DateFormat('d MMMM yyyy', 'ru').format(day)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
          ],
        ),
      );
      return;
    }
    final eventId = item['id'] as int? ?? int.tryParse('${item['id']}');
    if (eventId == null) return;
    final start = DateTime.tryParse(item['start_date']?.toString() ?? AgendaUtils.dateKey(day));
    final end = DateTime.tryParse(item['end_date']?.toString() ?? '');
    if (start == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CalendarEventEditScreen(
          eventId: eventId,
          initialDate: start,
          initialEndDate: end,
        ),
      ),
    );
    if (changed == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.5,
              child: Center(child: Text(_error!)),
            ),
          ],
        ),
      );
    }

    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return ValueListenableBuilder<bool>(
      valueListenable: _dayGestureCapture,
      builder: (context, gestureCapture, _) {
        return RefreshIndicator(
          notificationPredicate: (_) => !gestureCapture,
          onRefresh: _refresh,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return ListView(
                physics: gestureCapture
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                children: [
                  SizedBox(
                    height: constraints.maxHeight,
                    child: ScheduleCalendarPanel(
                      focusedDay: _focusedDay,
                      selectedDay: _selectedDay,
                      itemsByDate: _byDate,
                      readOnly: false,
                      onDayTap: _onAgendaDayTap,
                      onAgendaItemTap: _openAgendaItem,
                      onViewportChanged: (year, _, __, {required yearChanged, required dayOnlyViewport}) {
                        if (dayOnlyViewport != _dayOnlyViewport) {
                          setState(() => _dayOnlyViewport = dayOnlyViewport);
                        }
                        if (yearChanged && year != _loadedAgendaYear) {
                          _loadedAgendaYear = year;
                          setState(() => _displayYear = year);
                          _loadAgendaForYear(year: year, silent: _items.isNotEmpty);
                        } else if (yearChanged) {
                          _displayYear = year;
                        }
                      },
                      onDaySelected: (selected, focused) {
                        setState(() {
                          _selectedDay = selected;
                          _focusedDay = focused;
                        });
                      },
                      onSelectionModeChanged: (active) {
                        if (_dayGestureCapture.value != active) {
                          _dayGestureCapture.value = active;
                        }
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _DayEventsSheet extends StatelessWidget {
  const _DayEventsSheet({
    required this.day,
    required this.events,
    required this.onEventTap,
    required this.onCreate,
  });

  final DateTime day;
  final List<Map<String, dynamic>> events;
  final void Function(Map<String, dynamic> item) onEventTap;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = DateFormat('EEEE, d MMMM', 'ru').format(day);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (events.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Нет событий',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ...events.map(
                (e) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(e['title']?.toString() ?? ''),
                    trailing: e['editable'] == true
                        ? const Icon(Icons.chevron_right)
                        : null,
                    onTap: () => onEventTap(e),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Добавить событие'),
            ),
          ],
        ),
      ),
    );
  }
}
