import 'package:flutter/material.dart';

import '../../../profile/presentation/widgets/chat_avatar.dart';

class FeedPeopleFilterBar extends StatelessWidget {
  const FeedPeopleFilterBar({
    super.key,
    required this.people,
    required this.selectedUserId,
    required this.onSelected,
  });

  final List<Map<String, dynamic>> people;
  final int? selectedUserId;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    Widget avatarChip({
      required bool selected,
      required VoidCallback onTap,
      required Widget child,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.5),
                width: selected ? 2.5 : 1,
              ),
            ),
            child: child,
          ),
        ),
      );
    }

    return SizedBox(
      height: 52,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        scrollDirection: Axis.horizontal,
        children: [
          avatarChip(
            selected: selectedUserId == null,
            onTap: () => onSelected(null),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: cs.surfaceContainerHighest,
              child: Icon(Icons.people_outline, size: 20, color: cs.onSurfaceVariant),
            ),
          ),
          for (final person in people)
            avatarChip(
              selected: selectedUserId == person['user_id'],
              onTap: () => onSelected(person['user_id'] as int?),
              child: ChatAvatar(
                name: person['name']?.toString() ?? '',
                avatarUrl: person['avatar_url']?.toString(),
                radius: 18,
              ),
            ),
        ],
      ),
    );
  }
}

class FeedSectionDivider extends StatelessWidget {
  const FeedSectionDivider({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(
              height: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
