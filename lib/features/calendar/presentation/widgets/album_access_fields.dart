import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/providers/app_providers.dart';
import '../../../profile/presentation/widgets/chat_avatar.dart';

/// Блок «Кому доступен альбом» — как в диалоге создания альбома.
class AlbumAccessFields extends ConsumerStatefulWidget {
  const AlbumAccessFields({
    super.key,
    required this.accessMode,
    required this.selectedUserIds,
    required this.onAccessModeChanged,
    required this.onSelectedUserIdsChanged,
    this.enabled = true,
  });

  final String accessMode;
  final Set<int> selectedUserIds;
  final ValueChanged<String> onAccessModeChanged;
  final ValueChanged<Set<int>> onSelectedUserIdsChanged;
  final bool enabled;

  @override
  ConsumerState<AlbumAccessFields> createState() => _AlbumAccessFieldsState();
}

class _AlbumAccessFieldsState extends ConsumerState<AlbumAccessFields> {
  List<Map<String, dynamic>> _members = [];
  bool _loadingMembers = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final list = await ref.read(familychatRepositoryProvider).members();
      if (!mounted) return;
      setState(() {
        _members = list;
        _loadingMembers = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMembers = false);
    }
  }

  bool get _needsMembers =>
      widget.accessMode == 'allow' || widget.accessMode == 'deny';

  List<int> get _selectableMemberIds => _members
      .map((m) {
        final uid = m['user_id'];
        return uid is int ? uid : int.tryParse('$uid');
      })
      .whereType<int>()
      .toList();

  bool get _allMembersSelected {
    final ids = _selectableMemberIds;
    return ids.isNotEmpty && ids.every(widget.selectedUserIds.contains);
  }

  void _toggleSelectAllMembers() {
    final ids = _selectableMemberIds;
    final next = Set<int>.from(widget.selectedUserIds);
    if (_allMembersSelected) {
      next.removeAll(ids);
    } else {
      next.addAll(ids);
    }
    widget.onSelectedUserIdsChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Кому доступен альбом', style: Theme.of(context).textTheme.titleSmall),
        RadioListTile<String>(
          value: 'all',
          groupValue: widget.accessMode,
          onChanged: widget.enabled
              ? (v) => widget.onAccessModeChanged(v ?? 'all')
              : null,
          title: const Text('Всем'),
          contentPadding: EdgeInsets.zero,
        ),
        RadioListTile<String>(
          value: 'allow',
          groupValue: widget.accessMode,
          onChanged: widget.enabled
              ? (v) => widget.onAccessModeChanged(v ?? 'allow')
              : null,
          title: const Text('Только выбранным'),
          contentPadding: EdgeInsets.zero,
        ),
        RadioListTile<String>(
          value: 'deny',
          groupValue: widget.accessMode,
          onChanged: widget.enabled
              ? (v) => widget.onAccessModeChanged(v ?? 'deny')
              : null,
          title: const Text('Всем, кроме выбранных'),
          contentPadding: EdgeInsets.zero,
        ),
        if (_needsMembers) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: !widget.enabled || _loadingMembers || _selectableMemberIds.isEmpty
                  ? null
                  : _toggleSelectAllMembers,
              child: Text(_allMembersSelected ? 'Снять все' : 'Выбрать все'),
            ),
          ),
          if (_loadingMembers)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _members.length,
                itemBuilder: (context, i) {
                  final m = _members[i];
                  final uid = m['user_id'];
                  final userId = uid is int ? uid : int.tryParse('$uid');
                  if (userId == null) return const SizedBox.shrink();
                  final name = m['display_name']?.toString() ?? '';
                  return CheckboxListTile(
                    value: widget.selectedUserIds.contains(userId),
                    onChanged: widget.enabled
                        ? (v) {
                            final next = Set<int>.from(widget.selectedUserIds);
                            if (v == true) {
                              next.add(userId);
                            } else {
                              next.remove(userId);
                            }
                            widget.onSelectedUserIdsChanged(next);
                          }
                        : null,
                    secondary: ChatAvatar(
                      name: name,
                      avatarUrl: m['avatar_url']?.toString(),
                      radius: 18,
                    ),
                    title: Text(name),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  );
                },
              ),
            ),
        ],
      ],
    );
  }
}

String formatCalendarDateRange(String startIso, String endIso) {
  final start = DateTime.tryParse(startIso);
  final end = DateTime.tryParse(endIso);
  if (start == null) return startIso;
  if (end == null || _sameDay(start, end)) {
    return DateFormat('d MMMM yyyy', 'ru').format(start);
  }
  final sameYear = start.year == end.year;
  final sameMonth = sameYear && start.month == end.month;
  if (sameMonth) {
    return '${DateFormat('d', 'ru').format(start)}–${DateFormat('d MMMM yyyy', 'ru').format(end)}';
  }
  if (sameYear) {
    return '${DateFormat('d MMM', 'ru').format(start)} – ${DateFormat('d MMM yyyy', 'ru').format(end)}';
  }
  return '${DateFormat('d MMM yyyy', 'ru').format(start)} – ${DateFormat('d MMM yyyy', 'ru').format(end)}';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
