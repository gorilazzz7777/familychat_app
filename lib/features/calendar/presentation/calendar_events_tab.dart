import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/app_providers.dart';
import 'calendar_event_edit_screen.dart';
import 'widgets/album_access_fields.dart';

class CalendarEventsTab extends ConsumerStatefulWidget {
  const CalendarEventsTab({
    super.key,
    required this.reloadToken,
    this.onOpenCreate,
  });

  final int reloadToken;
  final VoidCallback? onOpenCreate;

  @override
  ConsumerState<CalendarEventsTab> createState() => _CalendarEventsTabState();
}

class _CalendarEventsTabState extends ConsumerState<CalendarEventsTab> {
  late DateTime _month;
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  @override
  void didUpdateWidget(covariant CalendarEventsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(familychatRepositoryProvider).calendar(
            year: _month.year,
            month: _month.month,
          );
      if (!mounted) return;
      setState(() {
        _events = (data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _shiftMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
    _load();
  }

  String _monthTitle() => DateFormat('LLLL yyyy', 'ru').format(_month);

  String _dayLabel(String isoDate) {
    final d = DateTime.tryParse(isoDate);
    if (d == null) return isoDate;
    return DateFormat('d MMMM', 'ru').format(d);
  }

  IconData _iconForKind(String? kind) {
    return switch (kind) {
      'birthday' => Icons.cake_outlined,
      'custom' => Icons.event_note_outlined,
      _ => Icons.celebration_outlined,
    };
  }

  Color _iconColor(BuildContext context, String? kind) {
    final cs = Theme.of(context).colorScheme;
    return switch (kind) {
      'birthday' => cs.tertiary,
      'custom' => cs.secondary,
      _ => cs.primary,
    };
  }

  Future<void> _openCustomEvent(Map<String, dynamic> event) async {
    final id = event['id'];
    final eventId = id is int ? id : int.tryParse('$id');
    if (eventId == null) return;
    final start = DateTime.tryParse(event['start_date']?.toString() ?? event['date']?.toString() ?? '');
    final end = DateTime.tryParse(event['end_date']?.toString() ?? '');
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
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Предыдущий месяц',
                onPressed: _loading ? null : () => _shiftMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  _monthTitle(),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Следующий месяц',
                onPressed: _loading ? null : () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : _events.isEmpty
                      ? Center(
                          child: Text(
                            'В этом месяце нет событий',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: _events.length,
                            itemBuilder: (context, i) {
                              final e = _events[i];
                              final kind = e['kind']?.toString();
                              final isCustom = kind == 'custom';
                              final date = e['date']?.toString() ?? '';
                              final showDateHeader = i == 0 ||
                                  _events[i - 1]['date']?.toString() != date;
                              final startIso = e['start_date']?.toString() ?? date;
                              final endIso = e['end_date']?.toString() ?? date;
                              final subtitle = isCustom && startIso != endIso
                                  ? formatCalendarDateRange(startIso, endIso)
                                  : null;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (showDateHeader) ...[
                                    if (i > 0) const SizedBox(height: 12),
                                    Text(
                                      _dayLabel(date),
                                      style: theme.textTheme.labelLarge?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                  ],
                                  Card(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    child: ListTile(
                                      leading: Icon(
                                        _iconForKind(kind),
                                        color: _iconColor(context, kind),
                                      ),
                                      title: Text(e['title']?.toString() ?? ''),
                                      subtitle: subtitle != null ? Text(subtitle) : null,
                                      trailing: isCustom
                                          ? const Icon(Icons.chevron_right)
                                          : null,
                                      onTap: isCustom ? () => _openCustomEvent(e) : null,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }
}
