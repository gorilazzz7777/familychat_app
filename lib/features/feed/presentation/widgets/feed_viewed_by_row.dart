import 'package:flutter/material.dart';

import 'feed_people_list_sheet.dart';

class FeedViewedByRow extends StatelessWidget {
  const FeedViewedByRow({
    super.key,
    required this.viewedBy,
  });

  static const visibleNamesLimit = 3;

  final List<Map<String, dynamic>> viewedBy;

  @override
  Widget build(BuildContext context) {
    if (viewedBy.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final names = viewedBy.map((person) {
      final name = feedPersonDisplayName(person);
      return name.isEmpty ? 'Участник' : name;
    }).toList();

    final mutedStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final overflow = names.length - visibleNamesLimit;
    final visibleNames = overflow > 0
        ? names.take(visibleNamesLimit).join(', ')
        : names.join(', ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.visibility_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: overflow > 0
                ? Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('$visibleNames ', style: mutedStyle),
                      Tooltip(
                        message: 'Кто просмотрел',
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => FeedPeopleListSheet.show(
                              context,
                              title: 'Просмотрели',
                              people: viewedBy,
                              emptyText: 'Пока никто не просмотрел',
                            ),
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 1,
                              ),
                              child: Text(
                                'ещё +$overflow',
                                style: feedTappableCountStyle(
                                  theme,
                                  base: theme.textTheme.labelMedium,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Text(visibleNames, style: mutedStyle),
          ),
        ],
      ),
    );
  }
}
