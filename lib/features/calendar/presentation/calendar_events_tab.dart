import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/network/offline_ui.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../gallery/presentation/gallery_albums_grouped_view.dart';
import 'calendar_event_edit_screen.dart';
import 'birthday_detail_screen.dart';
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
    final cached = await FamilyChatLocalCache.readCalendarMonth(
      year: _month.year,
      month: _month.month,
    );
    if (cached != null && mounted) {
      final events =
          (cached['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      setState(() {
        _events = events;
        _loading = false;
        _error = null;
      });
    } else if (_events.isEmpty && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final repo = ref.read(familychatRepositoryProvider);
    try {
      final data = await repo.calendar(
        year: _month.year,
        month: _month.month,
      );
      await FamilyChatLocalCache.saveCalendarMonth(
        year: _month.year,
        month: _month.month,
        data: data,
      );
      if (!mounted) return;
      final events =
          (data['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final same = _eventsFingerprint(_events) == _eventsFingerprint(events);
      if (same && !_loading) return;
      setState(() {
        _events = events;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_events.isNotEmpty) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _loading = false;
        _error = OfflineUi.loadErrorMessage(
          e,
          fallback: 'Не удалось загрузить события',
        );
      });
    }
  }

  String _eventsFingerprint(List<Map<String, dynamic>> events) {
    return events
        .map((e) => '${e['id']}|${e['date']}|${e['title']}|${e['kind']}')
        .join(';');
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
    if (event['editable'] != true) {
      final rawAlbum = event['gallery_album_id'];
      final albumPk = rawAlbum is int ? rawAlbum : int.tryParse('$rawAlbum');
      final rawOwner = event['owner_user_id'];
      final ownerUserId = rawOwner is int ? rawOwner : int.tryParse('$rawOwner');
      if (event['is_participant'] == true && albumPk != null && ownerUserId != null) {
        await openProfileGalleryAlbum(
          context,
          userId: ownerUserId,
          albumId: 'custom:$albumPk',
          title: event['title']?.toString() ?? 'Альбом события',
          canManage: false,
          canAddPhotos: true,
        );
      }
      return;
    }
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

  Future<void> _openBirthdayEvent(Map<String, dynamic> event) async {
    final userId = event['person_user_id'];
    final honoreeUserId = userId is int ? userId : int.tryParse('$userId');
    if (honoreeUserId == null) return;
    final date = event['date']?.toString() ?? '';
    final parsed = DateTime.tryParse(date);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BirthdayDetailScreen(
          honoreeUserId: honoreeUserId,
          initialTitle: event['title']?.toString() ?? 'День рождения',
          eventDate: date,
          year: parsed?.year ?? _month.year,
        ),
      ),
    );
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
              ? const DeferredPlaceholder(
                  child: Center(child: CircularProgressIndicator()),
                )
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
                              final isBirthday = kind == 'birthday';
                              final isTappable = isCustom || isBirthday;
                              final isPast = isCalendarEventPast(e);
                              final date = e['date']?.toString() ?? '';
                              final showDateHeader = i == 0 ||
                                  _events[i - 1]['date']?.toString() != date;
                              final startIso = e['start_date']?.toString() ?? date;
                              final endIso = e['end_date']?.toString() ?? date;
                              final subtitle = isCustom && startIso != endIso
                                  ? formatCalendarDateRange(startIso, endIso)
                                  : null;
                              final pastTint = const Color(0xFFE8F5E9);
                              final pastFg = const Color(0xFF5A8F6A);
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
                                    color: isPast ? pastTint : null,
                                    child: ListTile(
                                      leading: Icon(
                                        _iconForKind(kind),
                                        color: isPast
                                            ? pastFg
                                            : _iconColor(context, kind),
                                      ),
                                      title: Text(
                                        e['title']?.toString() ?? '',
                                        style: isPast
                                            ? theme.textTheme.bodyLarge?.copyWith(
                                                color: pastFg,
                                              )
                                            : null,
                                      ),
                                      subtitle: subtitle != null
                                          ? Text(
                                              subtitle,
                                              style: isPast
                                                  ? TextStyle(
                                                      color: pastFg.withValues(
                                                        alpha: 0.8,
                                                      ),
                                                    )
                                                  : null,
                                            )
                                          : null,
                                      trailing: isTappable
                                          ? Icon(
                                              Icons.chevron_right,
                                              color: isPast ? pastFg : null,
                                            )
                                          : null,
                                      onTap: isCustom
                                          ? () => _openCustomEvent(e)
                                          : isBirthday
                                              ? () => _openBirthdayEvent(e)
                                              : null,
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

/// Событие считается прошедшим, если его конец уже раньше [now].
///
/// Если есть только дата (без времени), границей считается конец этого дня
/// в локальной зоне. Если есть только старт — используется старт (или конец
/// дня, когда у старта нет времени).
bool isCalendarEventPast(Map<String, dynamic> event, {DateTime? now}) {
  final cutoff = calendarEventCutoff(event);
  if (cutoff == null) return false;
  return cutoff.isBefore(now ?? DateTime.now());
}

DateTime? calendarEventCutoff(Map<String, dynamic> event) {
  final endRaw = _firstNonEmpty(event, const ['end_date', 'end_at', 'ends_at']);
  if (endRaw != null) {
    return _parseEventCutoff(endRaw, timeHHmm: _nonEmpty(event['end_time']));
  }

  final startRaw = _firstNonEmpty(
    event,
    const ['start_date', 'start_at', 'starts_at', 'date'],
  );
  if (startRaw != null) {
    return _parseEventCutoff(startRaw, timeHHmm: _nonEmpty(event['start_time']));
  }
  return null;
}

String? _firstNonEmpty(Map<String, dynamic> event, List<String> keys) {
  for (final key in keys) {
    final value = _nonEmpty(event[key]);
    if (value != null) return value;
  }
  return null;
}

String? _nonEmpty(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

DateTime? _parseEventCutoff(String raw, {String? timeHHmm}) {
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return null;
  final local = parsed.isUtc ? parsed.toLocal() : parsed;

  if (timeHHmm != null) {
    final parts = timeHHmm.split(':');
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(local.year, local.month, local.day, hour, minute);
  }

  final hasClockTime = raw.contains('T') ||
      RegExp(r'\d{4}-\d{2}-\d{2}\s+\d').hasMatch(raw);
  if (hasClockTime) {
    return local;
  }

  return DateTime(local.year, local.month, local.day, 23, 59, 59, 999);
}
