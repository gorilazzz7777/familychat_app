import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'family_tree_graph.dart';
import 'member_profile_screen.dart';

class FamilyTreeTab extends ConsumerStatefulWidget {
  const FamilyTreeTab({
    super.key,
    required this.currentUserId,
    this.onOpenOwnProfile,
  });

  final int? currentUserId;
  final VoidCallback? onOpenOwnProfile;

  @override
  ConsumerState<FamilyTreeTab> createState() => _FamilyTreeTabState();
}

class _FamilyTreeTabState extends ConsumerState<FamilyTreeTab> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _payload;
  int? _centerPersonId;
  int? _defaultCenterPersonId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(familychatRepositoryProvider).familyTree();
      if (!mounted) return;
      final centerRaw = data['center_person_id'];
      final centerPersonId = centerRaw is int ? centerRaw : int.tryParse('$centerRaw');
      setState(() {
        _payload = data;
        _defaultCenterPersonId = centerPersonId;
        _centerPersonId = centerPersonId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _openProfile(TreePerson person) {
    if (person.userId == widget.currentUserId) {
      widget.onOpenOwnProfile?.call();
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(
          userId: person.userId,
          onOpenOwnProfile: widget.onOpenOwnProfile,
        ),
      ),
    );
  }

  void _recenter(TreePerson person) {
    setState(() => _centerPersonId = person.personId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Центр дерева: ${person.displayName}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    final centerPersonId = _centerPersonId;
    final payload = _payload;
    if (centerPersonId == null || payload == null) {
      return const Center(child: Text('Нет данных для дерева'));
    }

    final graph = FamilyTreeGraph.fromPayload(payload, centerPersonId: centerPersonId);
    final visibleIds = graph.visiblePersonIds();
    if (visibleIds.length <= 1) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Icon(Icons.account_tree_outlined, size: 56),
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Пока недостаточно связей для дерева. Добавляйте родственников через приглашения — связи появятся здесь.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    final positions = graph.layoutPositions();
    final visibleEdges = graph.visibleEdges(visibleIds);
    final theme = Theme.of(context);
    const nodeWidth = 92.0;
    const nodeHeight = 108.0;
    const nodeRadius = 30.0;

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (final offset in positions.values) {
      minX = minX < offset.dx - nodeWidth / 2 ? minX : offset.dx - nodeWidth / 2;
      minY = minY < offset.dy - nodeHeight / 2 ? minY : offset.dy - nodeHeight / 2;
      maxX = maxX > offset.dx + nodeWidth / 2 ? maxX : offset.dx + nodeWidth / 2;
      maxY = maxY > offset.dy + nodeHeight / 2 ? maxY : offset.dy + nodeHeight / 2;
    }
    final canvasWidth = (maxX - minX + 120).clamp(360.0, 2400.0);
    final canvasHeight = (maxY - minY + 160).clamp(420.0, 2400.0);
    final shift = Offset(-minX + 60, -minY + 80);
    final shiftedPositions = {
      for (final entry in positions.entries) entry.key: entry.value + shift,
    };

    final centerPerson = graph.personsById[centerPersonId];
    final isDefaultCenter = centerPersonId == _defaultCenterPersonId;

    return Column(
      children: [
        if (!isDefaultCenter && centerPerson != null)
          Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Центр: ${centerPerson.displayName}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: _defaultCenterPersonId == null
                        ? null
                        : () => setState(() => _centerPersonId = _defaultCenterPersonId),
                    child: const Text('Вернуться ко мне'),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Короткое нажатие — профиль, долгое — сделать центром дерева',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: InteractiveViewer(
              minScale: 0.35,
              maxScale: 2.5,
              boundaryMargin: const EdgeInsets.all(120),
              child: SizedBox(
                width: canvasWidth,
                height: canvasHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomPaint(
                      size: Size(canvasWidth, canvasHeight),
                      painter: FamilyTreeEdgePainter(
                        edges: visibleEdges,
                        positions: shiftedPositions,
                        nodeRadius: nodeRadius,
                        color: theme.colorScheme.outline.withValues(alpha: 0.55),
                      ),
                    ),
                    for (final personId in visibleIds)
                      if (shiftedPositions[personId] case final position?)
                        Positioned(
                          left: position.dx - nodeWidth / 2,
                          top: position.dy - nodeHeight / 2,
                          width: nodeWidth,
                          height: nodeHeight,
                          child: _TreeNode(
                            person: graph.personsById[personId]!,
                            label: graph.relationLabel(personId),
                            isCenter: personId == centerPersonId,
                            onTap: () => _openProfile(graph.personsById[personId]!),
                            onLongPress: () => _recenter(graph.personsById[personId]!),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TreeNode extends StatelessWidget {
  const _TreeNode({
    required this.person,
    required this.label,
    required this.isCenter,
    required this.onTap,
    required this.onLongPress,
  });

  final TreePerson person;
  final String label;
  final bool isCenter;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isCenter ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                  width: isCenter ? 3 : 1.5,
                ),
                boxShadow: isCenter
                    ? [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(alpha: 0.25),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
              child: ChatAvatar(
                name: person.displayName,
                avatarUrl: person.avatarUrl.isEmpty ? null : person.avatarUrl,
                radius: isCenter ? 30 : 24,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              person.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: isCenter ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
