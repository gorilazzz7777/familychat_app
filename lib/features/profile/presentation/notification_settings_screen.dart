import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/push/push_registration_service.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/app_settings_controller.dart';
import '../../../core/widgets/family_app_bar.dart';

class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen> {
  bool _busy = false;

  Future<void> _apply(FamilyChatAppSettings next) async {
    setState(() => _busy = true);
    try {
      await ref.read(appSettingsProvider.notifier).update(next);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onMasterChanged(bool enabled) async {
    final current = ref.read(appSettingsProvider);
    if (enabled) {
      final granted = await PushRegistrationService.requestOsPermission();
      if (!mounted) return;
      if (granted) {
        await PushRegistrationService.registerGrantedToken(
          ref.read(familychatRepositoryProvider),
        );
      }
    }
    await _apply(current.copyWith(pushEnabled: enabled));
  }

  Future<void> _editPeriod({QuietPeriod? existing, int? index}) async {
    final canQuiet = ref.read(appSettingsProvider).canQuietHours;
    if (!canQuiet) {
      await _showPremiumDialog();
      return;
    }
    final result = await showDialog<QuietPeriod>(
      context: context,
      builder: (ctx) => _QuietPeriodDialog(initial: existing),
    );
    if (result == null || !mounted) return;
    final current = ref.read(appSettingsProvider);
    final next = [...current.quietPeriods];
    if (index != null && index >= 0 && index < next.length) {
      next[index] = result;
    } else {
      next.add(result);
    }
    await _apply(
      current.copyWith(
        quietPeriods: next,
        utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      ),
    );
  }

  Future<void> _removePeriod(int index) async {
    final current = ref.read(appSettingsProvider);
    final next = [...current.quietPeriods]..removeAt(index);
    await _apply(current.copyWith(quietPeriods: next));
  }

  Future<void> _showPremiumDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Premium'),
        content: const Text(
          'Тихие часы доступны с подпиской Premium или Family Premium.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Уведомления'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Получать уведомления'),
            subtitle: const Text('Все типы: сообщения, звонки, календарь, лента'),
            value: settings.pushEnabled,
            onChanged: _busy ? null : _onMasterChanged,
          ),
          if (settings.pushEnabled) ...[
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Сообщения'),
              value: settings.pushMessages,
              onChanged: _busy
                  ? null
                  : (v) => _apply(settings.copyWith(pushMessages: v)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Звонки'),
              value: settings.pushCalls,
              onChanged: _busy
                  ? null
                  : (v) => _apply(settings.copyWith(pushCalls: v)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Календарь'),
              value: settings.pushCalendar,
              onChanged: _busy
                  ? null
                  : (v) => _apply(settings.copyWith(pushCalendar: v)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Лента'),
              subtitle: const Text('Новые фото в семейной ленте'),
              value: settings.pushFeed,
              onChanged: _busy
                  ? null
                  : (v) => _apply(settings.copyWith(pushFeed: v)),
            ),
            const SizedBox(height: 16),
            Text(
              'Не беспокоить в период',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            if (!settings.canQuietHours)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.lock_outline),
                title: const Text('Тихие часы'),
                subtitle: const Text('Доступно в Premium'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showPremiumDialog,
              )
            else ...[
              if (settings.quietPeriods.isEmpty)
                Text(
                  'Периоды не заданы',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              for (var i = 0; i < settings.quietPeriods.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(settings.quietPeriods[i].label),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Изменить',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: _busy
                              ? null
                              : () => _editPeriod(
                                    existing: settings.quietPeriods[i],
                                    index: i,
                                  ),
                        ),
                        IconButton(
                          tooltip: 'Удалить',
                          icon: const Icon(Icons.delete_outline),
                          onPressed:
                              _busy ? null : () => _removePeriod(i),
                        ),
                      ],
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _editPeriod(),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить период'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _QuietPeriodDialog extends StatefulWidget {
  const _QuietPeriodDialog({this.initial});

  final QuietPeriod? initial;

  @override
  State<_QuietPeriodDialog> createState() => _QuietPeriodDialogState();
}

class _QuietPeriodDialogState extends State<_QuietPeriodDialog> {
  late TimeOfDay _start;
  late TimeOfDay _end;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start = _parse(widget.initial?.start) ?? const TimeOfDay(hour: 22, minute: 0);
    _end = _parse(widget.initial?.end) ?? const TimeOfDay(hour: 7, minute: 0);
  }

  TimeOfDay? _parse(String? raw) {
    final parts = (raw ?? '').split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
  }

  String _format(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickStart() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _start,
      initialEntryMode: TimePickerEntryMode.dialOnly,
      helpText: 'С',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _start = picked;
      _error = null;
    });
  }

  Future<void> _pickEnd() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _end,
      initialEntryMode: TimePickerEntryMode.dialOnly,
      helpText: 'До',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _end = picked;
      _error = null;
    });
  }

  void _submit() {
    if (_format(_start) == _format(_end)) {
      setState(() => _error = 'Укажите разное время «с» и «до»');
      return;
    }
    Navigator.pop(
      context,
      QuietPeriod(start: _format(_start), end: _format(_end)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Новый период' : 'Период'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'В выбранном промежутке уведомления не приходят — '
            'включая сообщения, звонки, календарь и ленту.',
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('С'),
            trailing: Text(
              _format(_start),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            onTap: _pickStart,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('До'),
            trailing: Text(
              _format(_end),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            onTap: _pickEnd,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
