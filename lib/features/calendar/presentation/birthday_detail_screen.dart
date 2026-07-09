import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/offline_ui.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/chat_conversation_screen.dart';

class BirthdayDetailScreen extends ConsumerStatefulWidget {
  const BirthdayDetailScreen({
    super.key,
    required this.honoreeUserId,
    required this.initialTitle,
    this.eventDate,
    this.year,
  });

  final int honoreeUserId;
  final String initialTitle;
  final String? eventDate;
  final int? year;

  @override
  ConsumerState<BirthdayDetailScreen> createState() => _BirthdayDetailScreenState();
}

class _BirthdayDetailScreenState extends ConsumerState<BirthdayDetailScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _year {
    if (widget.year != null) return widget.year!;
    final parsed = DateTime.tryParse(widget.eventDate ?? '');
    if (parsed != null) return parsed.year;
    return DateTime.now().year;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(familychatRepositoryProvider).birthdayDetail(
            userId: widget.honoreeUserId,
            year: _year,
          );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = OfflineUi.loadErrorMessage(
          e,
          fallback: 'Не удалось загрузить данные',
        );
      });
    }
  }

  Future<void> _setSkip(bool value) async {
    if (_data == null || _saving) return;
    setState(() => _saving = true);
    try {
      final data = await ref.read(familychatRepositoryProvider).updateBirthdayPreference(
            userId: widget.honoreeUserId,
            skipCongratulations: value,
            year: _year,
          );
      if (!mounted) return;
      setState(() {
        _data = data;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  String _formatEventDate(String? iso) {
    final parsed = DateTime.tryParse(iso ?? '');
    if (parsed == null) return '';
    return DateFormat('d MMMM yyyy', 'ru').format(parsed);
  }

  Future<void> _openChat() async {
    final threadId = _data?['thread_id'];
    if (threadId is! int) return;
    final title = _data?['thread_title']?.toString() ?? widget.initialTitle;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatConversationScreen(
          threadId: threadId,
          title: title,
          defaultTitle: title,
          kind: 'group',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _data?['honoree_name']?.toString() ?? widget.initialTitle;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'День рождения'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
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
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Icon(
                      Icons.cake_outlined,
                      size: 56,
                      color: theme.colorScheme.tertiary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _formatEventDate(
                        _data?['event_date']?.toString() ?? widget.eventDate,
                      ),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_data?['toggle_enabled'] == true) ...[
                      SwitchListTile(
                        title: const Text('Не хочу поздравлять'),
                        subtitle: const Text(
                          'Постоянная настройка: вас не добавят в чат подготовки к этому дню рождения.',
                        ),
                        value: _data?['skip_congratulations'] == true,
                        onChanged: _saving
                            ? null
                            : (value) {
                                unawaited(_setSkip(value));
                              },
                      ),
                    ] else if (_data?['group_created'] == true) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _data?['is_chat_participant'] == true
                                ? 'Группа подготовки уже создана. Чтобы не участвовать, покиньте чат в списке групп.'
                                : 'Группа подготовки создана. Именинник подключится в день праздника — чат откроется, когда вас добавят в участники.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ],
                    if (_data?['thread_id'] is int) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _openChat,
                        icon: const Icon(Icons.chat_outlined),
                        label: const Text('Открыть чат подготовки'),
                      ),
                    ],
                  ],
                ),
    );
  }
}
