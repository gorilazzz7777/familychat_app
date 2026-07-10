import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';
import 'widgets/album_access_fields.dart';

const _reminderOptions = <int?, String>{
  null: 'Без напоминания',
  10080: 'За неделю',
  4320: 'За 3 дня',
  1440: 'За 1 день',
};

class CalendarEventEditScreen extends ConsumerStatefulWidget {
  const CalendarEventEditScreen({
    super.key,
    this.eventId,
    required this.initialDate,
    this.initialEndDate,
  });

  final int? eventId;
  final DateTime initialDate;
  final DateTime? initialEndDate;

  bool get isEditing => eventId != null;

  @override
  ConsumerState<CalendarEventEditScreen> createState() =>
      _CalendarEventEditScreenState();
}

class _CalendarEventEditScreenState extends ConsumerState<CalendarEventEditScreen> {
  static final _dateFmt = DateFormat('d MMMM yyyy', 'ru');

  final _titleCtrl = TextEditingController();
  late DateTime _startDate;
  late DateTime _endDate;
  int? _reminderMinutes;
  bool _createAlbum = false;
  bool _autoSyncPhotos = false;
  String _albumAccessMode = 'all';
  Set<int> _albumAccessUserIds = {};
  Set<int> _participantUserIds = {};
  String _albumAddMode = 'owner';
  Set<int> _albumAddUserIds = {};
  List<Map<String, dynamic>> _members = [];
  bool _loadingMembers = true;
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _startDate = DateTime(
      widget.initialDate.year,
      widget.initialDate.month,
      widget.initialDate.day,
    );
    _endDate = widget.initialEndDate != null
        ? DateTime(
            widget.initialEndDate!.year,
            widget.initialEndDate!.month,
            widget.initialEndDate!.day,
          )
        : _startDate;
    if (widget.isEditing) {
      _load();
    }
    _loadMembers();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .fetchCalendarEvent(widget.eventId!);
      if (!mounted) return;
      final start = DateTime.tryParse(data['start_date']?.toString() ?? '');
      final end = DateTime.tryParse(data['end_date']?.toString() ?? '');
      setState(() {
        _titleCtrl.text = data['title']?.toString() ?? '';
        if (start != null) _startDate = start;
        if (end != null) _endDate = end;
        final reminder = data['reminder_minutes'];
        _reminderMinutes = reminder is int ? reminder : int.tryParse('$reminder');
        _createAlbum = data['create_album'] == true;
        _autoSyncPhotos = data['auto_sync_photos'] == true;
        _albumAccessMode = data['album_access_mode']?.toString() ?? 'all';
        final rawIds = data['album_access_user_ids'];
        if (rawIds is List) {
          _albumAccessUserIds = rawIds
              .map((e) => e is int ? e : int.tryParse('$e'))
              .whereType<int>()
              .toSet();
        }
        final rawParticipants = data['participant_user_ids'];
        if (rawParticipants is List) {
          _participantUserIds = rawParticipants
              .map((e) => e is int ? e : int.tryParse('$e'))
              .whereType<int>()
              .toSet();
        }
        _albumAddMode = data['album_add_mode']?.toString() ?? 'owner';
        final rawAddIds = data['album_add_user_ids'];
        if (rawAddIds is List) {
          _albumAddUserIds = rawAddIds
              .map((e) => e is int ? e : int.tryParse('$e'))
              .whereType<int>()
              .toSet();
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка загрузки: $e')),
      );
    }
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
      if (!mounted) return;
      setState(() => _loadingMembers = false);
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      locale: const Locale('ru'),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
        if (_endDate.isBefore(_startDate)) _endDate = _startDate;
      } else {
        _endDate = picked;
        if (_endDate.isBefore(_startDate)) _startDate = _endDate;
      }
    });
  }

  Map<String, dynamic> _buildBody() {
    return {
      'title': _titleCtrl.text.trim(),
      'start_date': _isoDate(_startDate),
      'end_date': _isoDate(_endDate),
      'reminder_minutes': _reminderMinutes,
      'create_album': _createAlbum,
      'auto_sync_photos': _createAlbum && _autoSyncPhotos,
      'album_access_mode': _albumAccessMode,
      'album_access_user_ids': _albumAccessUserIds.toList(),
      'participant_user_ids': _participantUserIds.toList(),
      'album_add_mode': _albumAddMode,
      'album_add_user_ids': _albumAddUserIds.toList(),
    };
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Укажите название')),
      );
      return;
    }
    if (_createAlbum &&
        _albumAccessMode != 'all' &&
        _albumAccessUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите участников для альбома')),
      );
      return;
    }
    if (_createAlbum &&
        _albumAddMode == 'selected' &&
        _albumAddUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите, кто может добавлять фото')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final body = _buildBody();
      if (widget.isEditing) {
        await repo.updateCalendarEvent(widget.eventId!, body);
      } else {
        await repo.createCalendarEvent(body);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить событие?'),
        content: const Text('Это действие нельзя отменить.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(familychatRepositoryProvider)
          .deleteCalendarEvent(widget.eventId!);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  bool get _showAndroidAutoSync =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: FamilyAppBar.build(
        title: widget.isEditing ? 'Редактировать событие' : 'Новое событие',
        actions: [
          if (widget.isEditing)
            IconButton(
              tooltip: 'Удалить',
              onPressed: _saving || _loading ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _EventSectionCard(
                  scheme: scheme,
                  title: 'Основное',
                  icon: Icons.event_note_rounded,
                  children: [
                    TextField(
                      controller: _titleCtrl,
                      enabled: !_saving,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Название',
                        hintText: 'Например: Семейный ужин',
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                        prefixIcon: Icon(
                          Icons.celebration_outlined,
                          color: scheme.primary,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: 0.7),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: scheme.primary, width: 2),
                        ),
                      ),
                      textCapitalization: TextCapitalization.sentences,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _DatePickerCard(
                            scheme: scheme,
                            label: 'Начало',
                            dateText: _dateFmt.format(_startDate),
                            icon: Icons.play_circle_outline_rounded,
                            onTap: _saving ? null : () => _pickDate(isStart: true),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _DatePickerCard(
                            scheme: scheme,
                            label: 'Конец',
                            dateText: _dateFmt.format(_endDate),
                            icon: Icons.flag_circle_outlined,
                            onTap: _saving ? null : () => _pickDate(isStart: false),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int?>(
                      value: _reminderMinutes,
                      decoration: InputDecoration(
                        labelText: 'Напоминание',
                        helperText: 'Push приходит в 12:00 по Москве',
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                        prefixIcon: Icon(
                          Icons.notifications_active_outlined,
                          color: scheme.primary,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: 0.7),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: scheme.primary, width: 2),
                        ),
                      ),
                      items: _reminderOptions.entries
                          .map(
                            (e) => DropdownMenuItem<int?>(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          )
                          .toList(),
                      onChanged: _saving
                          ? null
                          : (v) => setState(() => _reminderMinutes = v),
                    ),
                  ],
                ),
                _EventSectionCard(
                  scheme: scheme,
                  title: 'Участники события',
                  icon: Icons.people_alt_rounded,
                  trailing: _participantUserIds.isEmpty
                      ? null
                      : _CountBadge(
                          scheme: scheme,
                          count: _participantUserIds.length,
                        ),
                  children: [
                    Text(
                      'Выберите, кого включить в событие',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_loadingMembers)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_members.isEmpty)
                      Text(
                        'Участники семьи не найдены',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    else
                      ..._members.map((m) {
                        final uid = m['user_id'];
                        final userId = uid is int ? uid : int.tryParse('$uid');
                        if (userId == null) return const SizedBox.shrink();
                        final name = m['display_name']?.toString() ?? '';
                        final selected = _participantUserIds.contains(userId);
                        return _MemberSelectTile(
                          scheme: scheme,
                          name: name,
                          selected: selected,
                          enabled: !_saving,
                          onChanged: (v) => setState(() {
                            if (v) {
                              _participantUserIds.add(userId);
                            } else {
                              _participantUserIds.remove(userId);
                            }
                          }),
                        );
                      }),
                  ],
                ),
                _EventSectionCard(
                  scheme: scheme,
                  title: 'Фотоальбом',
                  icon: Icons.photo_album_outlined,
                  children: [
                    _ToggleRow(
                      scheme: scheme,
                      icon: Icons.create_new_folder_outlined,
                      title: 'Создать альбом',
                      subtitle: 'Привязать альбом к событию',
                      value: _createAlbum,
                      enabled: !_saving,
                      onChanged: (v) => setState(() {
                        _createAlbum = v;
                        if (!v) _autoSyncPhotos = false;
                      }),
                    ),
                    if (_createAlbum && _showAndroidAutoSync) ...[
                      const SizedBox(height: 8),
                      _ToggleRow(
                        scheme: scheme,
                        icon: Icons.sync_rounded,
                        title: 'Подтягивать фото с телефона',
                        subtitle: 'Автоматически добавлять снимки за даты события',
                        value: _autoSyncPhotos,
                        enabled: !_saving,
                        onChanged: (v) => setState(() => _autoSyncPhotos = v),
                      ),
                    ],
                    if (_createAlbum) ...[
                      const SizedBox(height: 16),
                      Divider(
                        height: 1,
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 16),
                      AlbumAccessFields(
                        accessMode: _albumAccessMode,
                        selectedUserIds: _albumAccessUserIds,
                        enabled: !_saving,
                        onAccessModeChanged: (mode) =>
                            setState(() => _albumAccessMode = mode),
                        onSelectedUserIdsChanged: (ids) =>
                            setState(() => _albumAccessUserIds = ids),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Кто может добавлять фото',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _AlbumAddOptionTile(
                        scheme: scheme,
                        title: 'Только создатель',
                        selected: _albumAddMode == 'owner',
                        enabled: !_saving,
                        onTap: () => setState(() => _albumAddMode = 'owner'),
                      ),
                      _AlbumAddOptionTile(
                        scheme: scheme,
                        title: 'Все участники семьи',
                        selected: _albumAddMode == 'all',
                        enabled: !_saving,
                        onTap: () => setState(() => _albumAddMode = 'all'),
                      ),
                      _AlbumAddOptionTile(
                        scheme: scheme,
                        title: 'Выбранные участники',
                        selected: _albumAddMode == 'selected',
                        enabled: !_saving,
                        onTap: () => setState(() => _albumAddMode = 'selected'),
                      ),
                      if (_albumAddMode == 'selected') ...[
                        const SizedBox(height: 8),
                        ..._members.map((m) {
                          final uid = m['user_id'];
                          final userId = uid is int ? uid : int.tryParse('$uid');
                          if (userId == null) return const SizedBox.shrink();
                          final name = m['display_name']?.toString() ?? '';
                          final selected = _albumAddUserIds.contains(userId);
                          return _MemberSelectTile(
                            scheme: scheme,
                            name: name,
                            selected: selected,
                            enabled: !_saving,
                            onChanged: (v) => setState(() {
                              if (v) {
                                _albumAddUserIds.add(userId);
                              } else {
                                _albumAddUserIds.remove(userId);
                              }
                            }),
                          );
                        }),
                      ],
                    ],
                  ],
                ),
              ],
            ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: FilledButton(
              onPressed: _saving || _loading ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 2,
              ),
              child: _saving
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onPrimary,
                      ),
                    )
                  : Text(
                      widget.isEditing ? 'Сохранить' : 'Создать',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EventSectionCard extends StatelessWidget {
  const _EventSectionCard({
    required this.scheme,
    required this.title,
    required this.icon,
    required this.children,
    this.trailing,
  });

  final ColorScheme scheme;
  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.07),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: scheme.onPrimaryContainer, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.scheme, required this.count});

  final ColorScheme scheme;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _DatePickerCard extends StatelessWidget {
  const _DatePickerCard({
    required this.scheme,
    required this.label,
    required this.dateText,
    required this.icon,
    required this.onTap,
  });

  final ColorScheme scheme;
  final String label;
  final String dateText;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                dateText,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberSelectTile extends StatelessWidget {
  const _MemberSelectTile({
    required this.scheme,
    required this.name,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final ColorScheme scheme;
  final String name;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? () => onChanged(!selected) : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: selected ? scheme.primary : scheme.primaryContainer,
                  child: Text(
                    initials,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? scheme.onPrimary : scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                Checkbox(
                  value: selected,
                  onChanged: enabled ? (v) => onChanged(v ?? false) : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.scheme,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final ColorScheme scheme;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: value
            ? scheme.primaryContainer.withValues(alpha: 0.4)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: value
              ? scheme.primary.withValues(alpha: 0.35)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

class _AlbumAddOptionTile extends StatelessWidget {
  const _AlbumAddOptionTile({
    required this.scheme,
    required this.title,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ColorScheme scheme;
  final String title;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.5)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
