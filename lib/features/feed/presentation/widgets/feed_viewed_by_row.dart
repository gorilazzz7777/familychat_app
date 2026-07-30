import 'package:flutter/material.dart';

class FeedViewedByRow extends StatelessWidget {
  const FeedViewedByRow({
    super.key,
    required this.viewedBy,
  });

  final List<Map<String, dynamic>> viewedBy;

  @override
  Widget build(BuildContext context) {
    if (viewedBy.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final names = viewedBy
        .map((e) => e['first_name']?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    if (names.isEmpty) return const SizedBox.shrink();

    final label = names.length <= 3
        ? names.join(', ')
        : '${names.take(3).join(', ')} \u0438 \u0435\u0449\u0451 ${names.length - 3}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.visibility_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}