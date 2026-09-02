import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
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

/// «+» в ленте: подменю «Моё» / имя ребёнка (без шторки и подписей).
class FeedPostMenuButton extends ConsumerStatefulWidget {
  const FeedPostMenuButton({
    super.key,
    required this.onTargetSelected,
  });

  final ValueChanged<FeedPostTarget> onTargetSelected;

  @override
  ConsumerState<FeedPostMenuButton> createState() => _FeedPostMenuButtonState();
}

class _FeedPostMenuButtonState extends ConsumerState<FeedPostMenuButton> {
  List<FeedPostTargetChild> _children = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadChildren());
  }

  Future<void> _loadChildren() async {
    final children = await loadFeedPostChildTargets(
      ref.read(familychatRepositoryProvider),
    );
    if (!mounted) return;
    setState(() {
      _children = children;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return IconButton(
        icon: const Icon(Icons.add),
        onPressed: null,
      );
    }
    if (_children.isEmpty) {
      return IconButton(
        icon: const Icon(Icons.add),
        onPressed: () => widget.onTargetSelected(const FeedPostTargetSelf()),
      );
    }
    return PopupMenuButton<FeedPostTarget>(
      icon: const Icon(Icons.add),
      onSelected: widget.onTargetSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: FeedPostTargetSelf(),
          child: Text('Моё'),
        ),
        for (final child in _children)
          PopupMenuItem(
            value: child,
            child: Text(child.displayName),
          ),
      ],
    );
  }
}
