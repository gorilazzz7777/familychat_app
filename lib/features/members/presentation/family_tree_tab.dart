import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/offline_ui.dart';
import '../../../core/providers/app_providers.dart';
import '../../chat/data/chat_offline_sync.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'family_tree_graph.dart';
import 'kinship_link_sheet.dart';
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
  bool _previewing = false;
  bool _saving = false;
  String? _error;
  Map<String, dynamic>? _payload;
  int? _centerPersonId;
  int? _defaultCenterPersonId;
  Map<int, String?> _savedLinks = {};
  final Map<int, String?> _draftChanges = {};
  List<Map<String, dynamic>> _kinshipOptions = [];
  List<int> _disconnectedPersonIds = [];

  bool get _hasDraft => _draftChanges.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
    _loadKinshipOptions();
  }

  Future<void> _loadKinshipOptions() async {
    try {
      final opts = await ref.read(familychatRepositoryProvider).kinshipOptions();
      if (!mounted) return;
      setState(() => _kinshipOptions = opts);
    } catch (_) {}
  }

  Map<int, String?> _parseViewerLinks(Map<String, dynamic>? payload) {
    final raw = payload?['viewer_links'];
    if (raw is! Map) return {};
    final result = <int, String?>{};
    raw.forEach((key, value) {
      final personId = int.tryParse('$key');
      if (personId == null) return;
      if (value == null) {
        result[personId] = null;
        return;
      }
      final code = value.toString().trim();
      result[personId] = code.isEmpty ? null : code;
    });
    return result;
  }

  List<int> _parseDisconnected(Map<String, dynamic>? payload) {
    final raw = payload?['disconnected_person_ids'];
    if (raw is! List) return [];
    return raw
        .map((id) => id is int ? id : int.tryParse('$id'))
        .whereType<int>()
        .toList();
  }

  void _applyPayload(Map<String, dynamic> data, {bool resetDraft = true}) {
    final centerRaw = data['center_person_id'];
    final centerPersonId =
        centerRaw is int ? centerRaw : int.tryParse('$centerRaw');
    setState(() {
      _payload = data;
      _defaultCenterPersonId ??= centerPersonId;
      _centerPersonId = centerPersonId;
      _savedLinks = _parseViewerLinks(data);
      _disconnectedPersonIds = _parseDisconnected(data);
      if (resetDraft) _draftChanges.clear();
      _loading = false;
      _previewing = false;
      _saving = false;
    });
  }

  Future<void> _load({bool resetDraft = true}) async {
    final repo = ref.read(familychatRepositoryProvider);
    final online = await ChatOfflineSync.instance.refreshOnline(repo);
    if (!online) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await repo.familyTree();
      if (!mounted) return;
      _applyPayload(data, resetDraft: resetDraft);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _previewing = false;
        _saving = false;
        _error = OfflineUi.loadErrorMessage(
              e,
              fallback: 'Не удалось загрузить дерево',
            ) ??
            'Не удалось загрузить дерево';
      });
    }
  }

  String? _effectiveLinkCode(int personId) {
    if (_draftChanges.containsKey(personId)) return _draftChanges[personId];
    return _savedLinks[personId];
  }

  bool _viewerDirectLinkBlocked(int personId) {
    if (_draftChanges.containsKey(personId)) {
      final code = _draftChanges[personId];
      return code == null || code.isEmpty;
    }
    if (_savedLinks.containsKey(personId)) {
      final code = _savedLinks[personId];
      return code == null || code.isEmpty;
    }
    return false;
  }

  Map<String, dynamic> _payloadForDisplay(int centerPersonId) {
    final payload = Map<String, dynamic>.from(_payload!);
    final rawEdges = payload['edges'];
    if (rawEdges is! List) return payload;

    final edges = rawEdges.cast<Map<String, dynamic>>().where((edge) {
      final fromRaw = edge['from_person_id'];
      final toRaw = edge['to_person_id'];
      final from = fromRaw is int ? fromRaw : int.tryParse('$fromRaw');
      final to = toRaw is int ? toRaw : int.tryParse('$toRaw');
      if (from == null || to == null) return false;
      if (from != centerPersonId && to != centerPersonId) return true;
      final other = from == centerPersonId ? to : from;
      return !_viewerDirectLinkBlocked(other);
    }).toList();

    payload['edges'] = edges;
    return payload;
  }

  List<Map<String, dynamic>> _changesPayload() {
    return _draftChanges.entries
        .map(
          (e) => {
            'target_person_id': e.key,
            'relationship_code': e.value,
          },
        )
        .toList();
  }

  Future<void> _previewDraft() async {
    if (_draftChanges.isEmpty) {
      await _load(resetDraft: true);
      return;
    }
    setState(() => _previewing = true);
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .previewFamilyTreeKinshipChanges(_changesPayload());
      if (!mounted) return;
      _applyPayload(data, resetDraft: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _previewing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            OfflineUi.loadErrorMessage(
                  e,
                  fallback: 'Не удалось обновить предпросмотр',
                ) ??
                'Не удалось обновить предпросмотр',
          ),
        ),
      );
    }
  }

  Future<void> _saveDraft() async {
    if (!_hasDraft || _saving) return;
    if (_disconnectedPersonIds.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не у всех участников есть связь в семье. Добавьте связи перед сохранением.',
          ),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .saveFamilyTreeKinshipChanges(_changesPayload());
      if (!mounted) return;
      _applyPayload(data, resetDraft: true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Связи сохранены')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            OfflineUi.loadErrorMessage(
                  e,
                  fallback: 'Не удалось сохранить связи',
                ) ??
                'Не удалось сохранить связи',
          ),
        ),
      );
    }
  }

  Future<void> _cancelDraft() async {
    if (!_hasDraft) return;
    setState(() {
      _draftChanges.clear();
      _centerPersonId = _defaultCenterPersonId;
    });
    await _load(resetDraft: true);
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

  Future<void> _onPersonTap(TreePerson person, {required bool canEditLinks}) async {
    final isSelf = person.personId == _defaultCenterPersonId;
    if (!canEditLinks || isSelf) {
      _openProfile(person);
      return;
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Профиль'),
              onTap: () => Navigator.pop(ctx, 'profile'),
            ),
            ListTile(
              leading: const Icon(Icons.family_restroom_outlined),
              title: const Text('Связь'),
              subtitle: Text(_linkLabelForPerson(person.personId) ?? 'Не указана'),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'profile') {
      _openProfile(person);
      return;
    }
    if (action == 'link') await _openKinshipLink(person);
  }

  String? _linkLabelForPerson(int personId) {
    final code = _effectiveLinkCode(personId);
    if (code == null || code.isEmpty) return null;
    for (final option in _kinshipOptions) {
      if (option['code']?.toString() == code) {
        return option['label']?.toString();
      }
    }
    return code;
  }

  Future<void> _openKinshipLink(TreePerson person) async {
    if (_kinshipOptions.isEmpty) await _loadKinshipOptions();
    if (!mounted) return;
    final result = await showKinshipLinkSheet(
      context,
      personName: person.displayName,
      options: _kinshipOptions,
      currentCode: _effectiveLinkCode(person.personId),
    );
    if (!mounted || result == null) return;

    final normalized = result.trim().isEmpty ? null : result.trim();
    final saved = _savedLinks[person.personId];
    setState(() {
      if (normalized == saved) {
        _draftChanges.remove(person.personId);
      } else {
        _draftChanges[person.personId] = normalized;
      }
    });
    if (_draftChanges.isEmpty) {
      await _load(resetDraft: true);
      return;
    }
    await _previewDraft();
  }

  Widget _buildEmptyTree({
    required TreePerson? centerPerson,
    required FamilyTreeStats stats,
    required bool isDefaultCenter,
    required bool canEditLinks,
    required int centerPersonId,
    required Map<String, dynamic> payload,
  }) {
    final others = (payload['persons'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(TreePerson.fromJson)
        .where((p) => p.personId > 0 && p.personId != centerPersonId)
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

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
        if (_hasDraft)
          _DraftActionsBar(
            saving: _saving,
            previewing: _previewing,
            disconnected: _disconnectedPersonIds.isNotEmpty,
            onSave: _saveDraft,
            onCancel: _cancelDraft,
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(resetDraft: !_hasDraft),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              children: [
                const Icon(Icons.account_tree_outlined, size: 56),
                const SizedBox(height: 12),
                const Text(
                  'Пока недостаточно связей для карты. Нажмите на участника и укажите, кто он для вас.',
                  textAlign: TextAlign.center,
                ),
                if (!isDefaultCenter) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Чтобы указать связи, вернитесь в центр карты («Ко мне»).',
                    textAlign: TextAlign.center,
                  ),
                ],
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  for (final person in others)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: ChatAvatar(
                          name: person.displayName,
                          avatarUrl:
                              person.avatarUrl.isEmpty ? null : person.avatarUrl,
                          radius: 20,
                        ),
                        title: Text(person.displayName),
                        subtitle: Text(
                          _linkLabelForPerson(person.personId) ?? 'Связь не указана',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _onPersonTap(person, canEditLinks: canEditLinks),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
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

    final graph = FamilyTreeGraph.fromPayload(
      _payloadForDisplay(centerPersonId),
      centerPersonId: centerPersonId,
    );
    final visibleIds = graph.visiblePersonIds();
    final centerPerson = graph.personsById[centerPersonId];
    final stats = graph.stats();
    final isDefaultCenter = centerPersonId == _defaultCenterPersonId;
    final canEditLinks = isDefaultCenter && !_saving;

    if (visibleIds.length <= 1) {
      return _buildEmptyTree(
        centerPerson: centerPerson,
        stats: stats,
        isDefaultCenter: isDefaultCenter,
        canEditLinks: canEditLinks,
        centerPersonId: centerPersonId,
        payload: payload,
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
        if (_hasDraft)
          _DraftActionsBar(
            saving: _saving,
            previewing: _previewing,
            disconnected: _disconnectedPersonIds.isNotEmpty,
            onSave: _saveDraft,
            onCancel: _cancelDraft,
          ),
        if (!isDefaultCenter)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              'Чтобы изменить связи, вернитесь в центр карты («Ко мне»).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              InteractiveViewer(
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
                              hasDraftChange: _draftChanges.containsKey(personId),
                              onTap: () => _onPersonTap(
                                graph.personsById[personId]!,
                                canEditLinks: canEditLinks,
                              ),
                              onLongPress: () => _recenter(graph.personsById[personId]!),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
              if (_previewing)
                const Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Обновляем дерево…'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DraftActionsBar extends StatelessWidget {
  const _DraftActionsBar({
    required this.saving,
    required this.previewing,
    required this.disconnected,
    required this.onSave,
    required this.onCancel,
  });

  final bool saving;
  final bool previewing;
  final bool disconnected;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (disconnected)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Не у всех участников есть связь — сохранение недоступно.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: saving || previewing ? null : onCancel,
                    child: const Text('Отменить'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: saving || previewing || disconnected ? null : onSave,
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Сохранить'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
                    avatarUrl:
                        centerPerson.avatarUrl.isEmpty ? null : centerPerson.avatarUrl,
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
    required this.hasDraftChange,
    required this.onTap,
    required this.onLongPress,
  });

  final TreePerson person;
  final String label;
  final bool isCenter;
  final bool hasDraftChange;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: hasDraftChange
                    ? theme.colorScheme.tertiary
                    : isCenter
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
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
              color: hasDraftChange
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
