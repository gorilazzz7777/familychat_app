import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import 'feed_people_list_sheet.dart';

/// Opens the viewed-by people sheet, refreshing from API when names are placeholders.
Future<void> openFeedViewedByPeople({
  required BuildContext context,
  required WidgetRef ref,
  required List<Map<String, dynamic>> viewedBy,
  int? eventId,
  ValueChanged<List<Map<String, dynamic>>>? onViewedByChanged,
}) async {
  var people = await resolveFeedPeopleLocally(
    viewedBy.map((e) => Map<String, dynamic>.from(e)).toList(growable: false),
  );
  if (!context.mounted) return;

  if ((feedPeopleHaveUnresolvedNames(people) || people.isEmpty) &&
      eventId != null &&
      eventId > 0) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ),
      ),
    );
    try {
      final data =
          await ref.read(familychatRepositoryProvider).markFeedEventViewed(eventId);
      if (!context.mounted) return;
      final next = (data['viewed_by'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      if (next.isNotEmpty) {
        people = await resolveFeedPeopleLocally(next);
        onViewedByChanged?.call(people);
      }
    } catch (_) {
      // Keep locally resolved list if the request fails.
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  if (!context.mounted) return;
  await FeedPeopleListSheet.show(
    context,
    title: 'Просмотрели',
    people: people,
    emptyText: 'Пока никто не просмотрел',
    resolveLocally: false,
  );
}

class FeedViewedByRow extends ConsumerStatefulWidget {
  const FeedViewedByRow({
    super.key,
    required this.viewedBy,
    this.eventId,
    this.onViewedByChanged,
  });

  /// Upper bound for how many names we try to show in-line.
  static const maxVisibleNames = 2;

  final List<Map<String, dynamic>> viewedBy;
  final int? eventId;
  final ValueChanged<List<Map<String, dynamic>>>? onViewedByChanged;

  @override
  ConsumerState<FeedViewedByRow> createState() => _FeedViewedByRowState();
}

class _FeedViewedByRowState extends ConsumerState<FeedViewedByRow> {
  Future<void> _openViewedByPeople() {
    return openFeedViewedByPeople(
      context: context,
      ref: ref,
      viewedBy: widget.viewedBy,
      eventId: widget.eventId,
      onViewedByChanged: widget.onViewedByChanged,
    );
  }

  double _measure(String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    return painter.width;
  }

  /// How many leading names fit on one line with an optional «ещё +N».
  /// Never clip «ещё» — drop names until the overflow label fits.
  ({int visibleCount, int overflow}) _fitNames({
    required List<String> names,
    required double maxWidth,
    required TextStyle? nameStyle,
    required TextStyle? overflowStyle,
  }) {
    if (names.isEmpty) return (visibleCount: 0, overflow: 0);
    final maxVisible = names.length < FeedViewedByRow.maxVisibleNames
        ? names.length
        : FeedViewedByRow.maxVisibleNames;

    for (var count = maxVisible; count >= 1; count--) {
      final visible = names.take(count).join(', ');
      final overflow = names.length - count;
      if (overflow <= 0) {
        if (_measure(visible, nameStyle) <= maxWidth) {
          return (visibleCount: count, overflow: 0);
        }
        continue;
      }
      final overflowLabel = 'ещё +$overflow';
      final total = _measure('$visible ', nameStyle) +
          _measure(overflowLabel, overflowStyle);
      if (total <= maxWidth) {
        return (visibleCount: count, overflow: overflow);
      }
    }

    // Names don't fit with «ещё» — show overflow only (full list in sheet).
    if (names.length > 1) {
      final overflowLabel = 'ещё +${names.length}';
      if (_measure(overflowLabel, overflowStyle) <= maxWidth) {
        return (visibleCount: 0, overflow: names.length);
      }
    }
    return (visibleCount: 1, overflow: 0);
  }

  @override
  Widget build(BuildContext context) {
    final viewedBy = widget.viewedBy;
    if (viewedBy.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final names = viewedBy.map((person) {
      final name = feedPersonShortName(person);
      return name.isEmpty ? 'Участник' : name;
    }).toList();

    final mutedStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final overflowStyle = feedTappableCountStyle(
      theme,
      base: theme.textTheme.labelMedium,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.eye,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final fit = _fitNames(
                  names: names,
                  maxWidth: constraints.maxWidth,
                  nameStyle: mutedStyle,
                  overflowStyle: overflowStyle,
                );
                final visibleNames =
                    names.take(fit.visibleCount).join(', ');

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _openViewedByPeople,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      // Keep «ещё +N» unclipped: names may shrink, label does not.
                      child: Row(
                        children: [
                          if (fit.visibleCount > 0)
                            Flexible(
                              child: Text(
                                visibleNames,
                                style: mutedStyle,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (fit.overflow > 0) ...[
                            if (fit.visibleCount > 0)
                              Text(' ', style: mutedStyle),
                            Text(
                              'ещё +${fit.overflow}',
                              style: overflowStyle,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
