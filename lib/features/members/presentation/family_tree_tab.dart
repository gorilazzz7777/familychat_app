import 'dart:math' as math;

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
    final centerPerson = graph.personsById[centerPersonId];
    final stats = graph.stats();
    final isDefaultCenter = centerPersonId == _defaultCenterPersonId;

    if (visibleIds.length <= 1) {
      return Column(
        children: [
          if (centerPerson != null)
            _FamilyTreeHeader(
              centerPerson: centerPerson,
              stats: stats,
              isDefaultCenter: isDefaultCenter,
              onReturnToMe: isDefaultCenter
                  ? null
                  : () => setState(() => _centerPersonId = _defaultCenterPersonId),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 48),
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
            ),
          ),
        ],
      );
    }

    final positions = graph.layoutPositions();
    final visibleEdges = graph.visibleEdges(visibleIds);
    final theme = Theme.of(context);
    const nodeWidth = 92.0;
    const nodeHeight = 108.0;
    const nodeRadius = 30.0;
    const padH = 60.0;
    const padV = 80.0;

    double minX = double.infinity;
    double minY = double.infinity;
    for (final offset in positions.values) {
      minX = math.min(minX, offset.dx - nodeWidth / 2);
      minY = math.min(minY, offset.dy - nodeHeight / 2);
    }
    final shift = Offset(-minX + padH, -minY + padV);
    final shiftedPositions = {
      for (final entry in positions.entries) entry.key: entry.value + shift,
    };

    var canvasWidth = padH;
    var canvasHeight = padV;
    for (final position in shiftedPositions.values) {
      canvasWidth = math.max(canvasWidth, position.dx + nodeWidth / 2 + padH);
      canvasHeight = math.max(canvasHeight, position.dy + nodeHeight / 2 + padV);
    }
    canvasWidth = math.max(canvasWidth, 360.0);
    canvasHeight = math.max(canvasHeight, 420.0);

    final sortedPersonIds = visibleIds.toList()
      ..sort((a, b) {
        if (a == centerPersonId) return 1;
        if (b == centerPersonId) return -1;
        return a.compareTo(b);
      });

    return Column(
      children: [
        if (centerPerson != null)
          _FamilyTreeHeader(
            centerPerson: centerPerson,
            stats: stats,
            isDefaultCenter: isDefaultCenter,
            onReturnToMe: isDefaultCenter
                ? null
                : () => setState(() => _centerPersonId = _defaultCenterPersonId),
          ),
        Expanded(
          child: InteractiveViewer(
            constrained: false,
            panEnabled: true,
            scaleEnabled: true,
            minScale: 0.25,
            maxScale: 3.5,
            boundaryMargin: const EdgeInsets.all(240),
            clipBehavior: Clip.none,
            child: SizedBox(
              width: canvasWidth,
              height: canvasHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  IgnorePointer(
                    child: CustomPaint(
                      size: Size(canvasWidth, canvasHeight),
                      painter: FamilyTreeEdgePainter(
                        edges: visibleEdges,
                        positions: shiftedPositions,
                        nodeRadius: nodeRadius,
                        color: theme.colorScheme.outline.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  for (final personId in sortedPersonIds)
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
      ],
    );
  }
}

class _FamilyTreeHeader extends StatelessWidget {
  const _FamilyTreeHeader({
    required this.centerPerson,
    required this.stats,
    required this.isDefaultCenter,
    this.onReturnToMe,
  });

  final TreePerson centerPerson;
  final FamilyTreeStats stats;
  final bool isDefaultCenter;
  final VoidCallback? onReturnToMe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              primary.withValues(alpha: 0.14),
              theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35),
            ],
          ),
          border: Border.all(color: primary.withValues(alpha: 0.18)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ChatAvatar(
                    name: centerPerson.displayName,
                    avatarUrl: centerPerson.avatarUrl.isEmpty ? null : centerPerson.avatarUrl,
                    radius: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Карта родства',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          centerPerson.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          isDefaultCenter ? 'Вы в центре карты' : 'Центр карты',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onReturnToMe != null)
                    TextButton(
                      onPressed: onReturnToMe,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('Ко мне'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _StatChip(
                      value: '${stats.familyTotal}',
                      label: 'в семье',
                      icon: Icons.people_outline,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StatChip(
                      value: '${stats.onMap}',
                      label: 'на карте',
                      icon: Icons.hub_outlined,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StatChip(
                      value: '${stats.nearby}',
                      label: 'рядом',
                      icon: Icons.near_me_outlined,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StatChip(
                      value: '${stats.links}',
                      label: 'связей',
                      icon: Icons.link,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.value,
    required this.label,
    required this.icon,
  });

  final String value;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.primary),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
        ],
      ),
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
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
