import '../../../../profile/presentation/birthday_format.dart';

enum ScrapbookPageKind { cover, achieved, ahead }

class ScrapbookSlot {
  const ScrapbookSlot({
    required this.milestone,
    required this.achieved,
  });

  final Map<String, dynamic> milestone;
  final bool achieved;
}

class ScrapbookPageModel {
  const ScrapbookPageModel({
    required this.kind,
    this.ageLabel,
    this.calendarLabel,
    this.sectionTitle,
    this.slots = const [],
    this.coverTitle,
    this.coverSubtitle,
  });

  final ScrapbookPageKind kind;
  final String? ageLabel;
  final String? calendarLabel;
  final String? sectionTitle;
  final List<ScrapbookSlot> slots;
  final String? coverTitle;
  final String? coverSubtitle;

  bool get isEmpty =>
      kind != ScrapbookPageKind.cover && slots.isEmpty;
}

const _achievedSlotsPerPage = 1;
const _aheadSlotsPerPage = 2;

List<ScrapbookPageModel> buildScrapbookPages({
  required List<Map<String, dynamic>> milestones,
  required String babyName,
  DateTime? birthDate,
  String Function(DateTime month)? calendarLabelBuilder,
  String Function(DateTime date)? ageLabelBuilder,
  bool includeAhead = true,
}) {
  final achieved = milestones.where((m) => m['achieved'] == true).toList()
    ..sort((a, b) {
      final da = _milestoneDate(a);
      final db = _milestoneDate(b);
      if (da == null && db == null) {
        return _sortOrder(a).compareTo(_sortOrder(b));
      }
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });

  final ahead = includeAhead
      ? (milestones.where((m) => m['achieved'] != true).toList()
        ..sort((a, b) => _sortOrder(a).compareTo(_sortOrder(b))))
      : <Map<String, dynamic>>[];

  final pages = <ScrapbookPageModel>[
    ScrapbookPageModel(
      kind: ScrapbookPageKind.cover,
      coverTitle: babyName,
    ),
  ];

  final byMonth = <String, List<Map<String, dynamic>>>{};
  for (final m in achieved) {
    final d = _milestoneDate(m);
    if (d == null) continue;
    final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
    byMonth.putIfAbsent(key, () => []).add(m);
  }

  final monthKeys = byMonth.keys.toList()..sort();
  for (final key in monthKeys) {
    final items = byMonth[key]!;
    final sampleDate = _milestoneDate(items.first)!;
    final monthStart = DateTime(sampleDate.year, sampleDate.month, 1);
    final ageLabel = birthDate != null && ageLabelBuilder != null
        ? ageLabelBuilder(sampleDate)
        : null;
    final calendarLabel = calendarLabelBuilder != null
        ? calendarLabelBuilder(monthStart)
        : null;

    for (var i = 0; i < items.length; i += _achievedSlotsPerPage) {
      final chunk = items.sublist(
        i,
        i + _achievedSlotsPerPage > items.length
            ? items.length
            : i + _achievedSlotsPerPage,
      );
      pages.add(
        ScrapbookPageModel(
          kind: ScrapbookPageKind.achieved,
          ageLabel: i == 0 ? ageLabel : null,
          calendarLabel: i == 0 ? calendarLabel : null,
          slots: chunk
              .map((m) => ScrapbookSlot(milestone: m, achieved: true))
              .toList(),
        ),
      );
    }
  }

  if (ahead.isNotEmpty) {
    for (var i = 0; i < ahead.length; i += _aheadSlotsPerPage) {
      final chunk = ahead.sublist(
        i,
        i + _aheadSlotsPerPage > ahead.length
            ? ahead.length
            : i + _aheadSlotsPerPage,
      );
      pages.add(
        ScrapbookPageModel(
          kind: ScrapbookPageKind.ahead,
          sectionTitle: i == 0 ? 'Впереди нас ждёт' : null,
          slots: chunk
              .map((m) => ScrapbookSlot(milestone: m, achieved: false))
              .toList(),
        ),
      );
    }
  }

  if (pages.length == 1 && achieved.isEmpty && includeAhead) {
    pages.add(
      const ScrapbookPageModel(
        kind: ScrapbookPageKind.ahead,
        sectionTitle: 'Впереди нас ждёт',
        slots: [],
      ),
    );
  }

  return pages;
}

DateTime? _milestoneDate(Map<String, dynamic> milestone) {
  return parseBirthDate(milestone['achieved_at']?.toString());
}

int _sortOrder(Map<String, dynamic> milestone) {
  final raw = milestone['sort_order'];
  if (raw is int) return raw;
  return int.tryParse('$raw') ?? 0;
}
