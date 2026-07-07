import 'package:intl/intl.dart';

/// Утилиты объединённого расписания (тренировки + события).
abstract final class AgendaUtils {
  static final _dateKeyFmt = DateFormat('yyyy-MM-dd');

  static String dateKey(DateTime d) => _dateKeyFmt.format(d);

  static Map<String, List<Map<String, dynamic>>> groupByDisplayDate(
    List<Map<String, dynamic>> items,
  ) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final key = item['display_date']?.toString() ??
          item['scheduled_date']?.toString() ??
          '';
      if (key.isEmpty) continue;
      map.putIfAbsent(key, () => []).add(item);
    }
    for (final list in map.values) {
      list.sort(_compareItems);
    }
    return map;
  }

  static int _compareItems(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ta = _sortTime(a);
    final tb = _sortTime(b);
    final c = ta.compareTo(tb);
    if (c != 0) return c;
    return (a['title']?.toString() ?? '').compareTo(b['title']?.toString() ?? '');
  }

  static String _sortTime(Map<String, dynamic> item) {
    if (item['all_day'] == true ||
        item['kind'] == 'vacation' ||
        item['kind'] == 'sick') {
      return '00:00';
    }
    final t = item['start_time']?.toString();
    if (t != null && t.isNotEmpty) return t;
    return '99:99';
  }

  static String cellTitle(Map<String, dynamic> item) =>
      item['title']?.toString() ?? '';

  static String? cellTime(Map<String, dynamic> item) {
    if (item['all_day'] == true ||
        item['kind'] == 'vacation' ||
        item['kind'] == 'sick') {
      return null;
    }
    final time = item['start_time']?.toString();
    return (time != null && time.isNotEmpty) ? time : null;
  }

  static String cellLine(Map<String, dynamic> item) {
    final title = item['title']?.toString() ?? '';
    if (item['all_day'] == true) return title;
    final time = item['start_time']?.toString();
    if (time != null && time.isNotEmpty) return '$time $title';
    return title;
  }

  /// Строка для панели дня: «9-00 : 11-00 утро».
  static String detailPanelLine(Map<String, dynamic> item) {
    final kind = item['kind']?.toString();
    final title = cellTitle(item);
    final displayTitle = title.isNotEmpty
        ? title
        : (kind == 'workout' ? 'Тренировка' : 'Событие');

    if (item['all_day'] == true ||
        kind == 'vacation' ||
        kind == 'sick') {
      return displayTitle;
    }

    final start = cellTime(item);
    if (start == null) return displayTitle;

    final end = cellEndTime(item);
    final timePart = end != null && end != start
        ? '${_formatTimeHyphen(start)} : ${_formatTimeHyphen(end)}'
        : _formatTimeHyphen(start);
    return '$timePart $displayTitle';
  }

  static String? cellEndTime(Map<String, dynamic> item) {
    if (item['all_day'] == true ||
        item['kind'] == 'vacation' ||
        item['kind'] == 'sick') {
      return null;
    }
    final endRaw = item['end_time']?.toString();
    if (endRaw != null && endRaw.isNotEmpty) return endRaw;

    final startMin = parseMinutes(item['start_time']?.toString());
    if (startMin == null) return null;
    final endMin = startMin + durationMinutes(item);
    final h = endMin ~/ 60;
    final m = endMin % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static String _formatTimeHyphen(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length < 2) return hhmm;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return '$h-${m.toString().padLeft(2, '0')}';
  }

  static List<String> cellPreviewLines(List<Map<String, dynamic>> items, {int max = 3}) {
    final lines = items.take(max).map(cellLine).toList();
    if (items.length > max) {
      lines.add('+${items.length - max} ещё');
    }
    return lines;
  }

  static int? parseMinutes(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return null;
    final parts = hhmm.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return h * 60 + m;
  }

  static int durationMinutes(Map<String, dynamic> item) {
    if (item['kind'] == 'workout') {
      return item['duration_minutes'] as int? ?? 60;
    }
    final start = parseMinutes(item['start_time']?.toString());
    final end = parseMinutes(item['end_time']?.toString());
    if (start != null && end != null && end > start) return end - start;
    return 60;
  }

  static bool itemsOverlap(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a['all_day'] == true || b['all_day'] == true) return false;
    final aStart = parseMinutes(a['start_time']?.toString()) ?? 9 * 60;
    final bStart = parseMinutes(b['start_time']?.toString()) ?? 9 * 60;
    final aEnd = aStart + durationMinutes(a);
    final bEnd = bStart + durationMinutes(b);
    return aStart < bEnd && bStart < aEnd;
  }
}
