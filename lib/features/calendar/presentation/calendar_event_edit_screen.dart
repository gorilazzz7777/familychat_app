import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/app_providers.dart';
import 'widgets/album_access_fields.dart';

const _reminderOptions = <int?, String>{
  null: 'Без напоминания',
  15: 'За 15 минут',
  30: 'За 30 минут',
  60: 'За 1 час',
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Редактировать событие' : 'Новое событие'),
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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                TextField(
                  controller: _titleCtrl,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Дата начала'),
                  subtitle: Text(_dateFmt.format(_startDate)),
                  trailing: const Icon(Icons.calendar_month_outlined),
                  onTap: _saving ? null : () => _pickDate(isStart: true),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Дата конца'),
                  subtitle: Text(_dateFmt.format(_endDate)),
                  trailing: const Icon(Icons.event_outlined),
                  onTap: _saving ? null : () => _pickDate(isStart: false),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  value: _reminderMinutes,
                  decoration: const InputDecoration(
                    labelText: 'Напоминание',
                    border: OutlineInputBorder(),
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
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Создать альбом'),
                  value: _createAlbum,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                            _createAlbum = v;
                            if (!v) _autoSyncPhotos = false;
                          }),
                ),
                if (_createAlbum && _showAndroidAutoSync)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Подтягивать фото с телефона'),
                    value: _autoSyncPhotos,
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _autoSyncPhotos = v),
                  ),
                if (_createAlbum) ...[
                  const SizedBox(height: 8),
                  AlbumAccessFields(
                    accessMode: _albumAccessMode,
                    selectedUserIds: _albumAccessUserIds,
                    enabled: !_saving,
                    onAccessModeChanged: (mode) =>
                        setState(() => _albumAccessMode = mode),
                    onSelectedUserIdsChanged: (ids) =>
                        setState(() => _albumAccessUserIds = ids),
                  ),
                ],
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _saving || _loading ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.isEditing ? 'Сохранить' : 'Создать'),
          ),
        ),
      ),
    );
  }
}
