import 'package:flutter/material.dart';

import '../../familychat/data/familychat_repository.dart';

/// От чьего имени публикуется пост в ленту.
sealed class FeedPostTarget {
  const FeedPostTarget();
}

class FeedPostTargetSelf extends FeedPostTarget {
  const FeedPostTargetSelf();
}

class FeedPostTargetChild extends FeedPostTarget {
  const FeedPostTargetChild({
    required this.childId,
    required this.displayName,
    this.avatarUrl,
    this.gender = '',
  });

  final int childId;
  final String displayName;
  final String? avatarUrl;
  final String gender;
}

/// Дети с Dairy, от имени которых опекун может публиковать в ленту.
Future<List<FeedPostTargetChild>> loadFeedPostChildTargets(
  FamilyChatRepository repo,
) async {
  try {
    final diary = await repo.diaryShareStatus();
    if (diary['available'] != true) return const [];
    final children = await repo.children();
    final out = <FeedPostTargetChild>[];
    for (final raw in children) {
      if (raw['is_custodian'] != true) continue;
      final diaryBabyId = raw['diary_baby_id'];
      if (diaryBabyId == null) continue;
      final childId = raw['child_id'] ?? raw['id'];
      final id = childId is int ? childId : int.tryParse('$childId');
      if (id == null) continue;
      final name = raw['display_name']?.toString().trim();
      out.add(
        FeedPostTargetChild(
          childId: id,
          displayName: (name != null && name.isNotEmpty) ? name : 'Ребёнок',
          avatarUrl: raw['avatar_url']?.toString(),
          gender: raw['gender']?.toString() ?? '',
        ),
      );
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// «Моё» + каждый ребёнок; null — отмена.
Future<FeedPostTarget?> showFeedPostTargetPicker(
  BuildContext context, {
  required List<FeedPostTargetChild> children,
}) {
  return showModalBottomSheet<FeedPostTarget>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Кто публикует в ленту?',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Моё'),
              subtitle: const Text('Ваша галерея и профиль'),
              onTap: () => Navigator.pop(ctx, const FeedPostTargetSelf()),
            ),
            for (final child in children)
              ListTile(
                leading: CircleAvatar(
                  backgroundImage: (child.avatarUrl ?? '').isNotEmpty
                      ? NetworkImage(child.avatarUrl!)
                      : null,
                  child: (child.avatarUrl ?? '').isEmpty
                      ? Text(
                          child.displayName.isNotEmpty
                              ? child.displayName[0]
                              : '?',
                        )
                      : null,
                ),
                title: Text(child.displayName),
                subtitle: const Text('Галерея ребёнка и Dairy'),
                onTap: () => Navigator.pop(ctx, child),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
