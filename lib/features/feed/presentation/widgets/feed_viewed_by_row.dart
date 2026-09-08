import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import 'feed_people_list_sheet.dart';

class FeedViewedByRow extends ConsumerStatefulWidget {
  const FeedViewedByRow({
    super.key,
    required this.viewedBy,
    this.eventId,
    this.onViewedByChanged,
  });

  /// Upper bound for how many names we try to show in-line.
  static const maxVisibleNames = 3;

  final List<Map<String, dynamic>> viewedBy;
  final int? eventId;
  final ValueChanged<List<Map<String, dynamic>>>? onViewedByChanged;

  @override
  ConsumerState<FeedViewedByRow> createState() => _FeedViewedByRowState();
}

class _FeedViewedByRowState extends ConsumerState<FeedViewedByRow> {
  Future<void> _openViewedByPeople() async {
    var people = await resolveFeedPeopleLocally(
      widget.viewedBy
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false),
    );
    if (!mounted || people.isEmpty) return;

    final eventId = widget.eventId;
    if (feedPeopleHaveUnresolvedNames(people) && eventId != null) {
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
        final data = await ref
            .read(familychatRepositoryProvider)
            .markFeedEventViewed(eventId);
        if (!mounted) return;
        final next = (data['viewed_by'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
        if (next.isNotEmpty) {
          people = await resolveFeedPeopleLocally(next);
          widget.onViewedByChanged?.call(people);
        }
      } catch (_) {
        // Keep locally resolved list if the request fails.
      } finally {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!mounted || people.isEmpty) return;
    await FeedPeopleListSheet.show(
      context,
      title: 'Просмотрели',
      people: people,
      emptyText: 'Пока никто не просмотрел',
      resolveLocally: false,
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

    // Prefer showing as many as possible (up to 3) that still fit with overflow.
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

    // Even one full name may be too long — still show 1 + overflow.
    return (
      visibleCount: 1,
      overflow: names.length > 1 ? names.length - 1 : 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewedBy = widget.viewedBy;
    if (viewedBy.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final names = viewedBy.map((person) {
      final name = feedPersonDisplayName(person);
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
            Icons.visibility_outlined,
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
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: visibleNames, style: mutedStyle),
                            if (fit.overflow > 0) ...[
                              TextSpan(text: ' ', style: mutedStyle),
                              TextSpan(
                                text: 'ещё +${fit.overflow}',
                                style: overflowStyle,
                              ),
                            ],
                          ],
                        ),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
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
