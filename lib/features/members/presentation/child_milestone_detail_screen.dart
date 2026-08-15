import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_public_image.dart';

/// Деталка вехи в стиле Dairy (просмотр + правки для опекунов).
class ChildMilestoneDetailScreen extends ConsumerStatefulWidget {
  const ChildMilestoneDetailScreen({
    super.key,
    required this.code,
    this.initial,
    this.canEdit = false,
  });

  final String code;
  final Map<String, dynamic>? initial;
  final bool canEdit;

  @override
  ConsumerState<ChildMilestoneDetailScreen> createState() =>
      _ChildMilestoneDetailScreenState();
}

class _ChildMilestoneDetailScreenState
    extends ConsumerState<ChildMilestoneDetailScreen> {
  Map<String, dynamic>? _milestone;
  final _note = TextEditingController();
  final _weight = TextEditingController();
  final _height = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _achieved = false;
  DateTime? _achievedAt;

  @override
  void initState() {
    super.initState();
    _apply(widget.initial);
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    _weight.dispose();
    _height.dispose();
    super.dispose();
  }

  void _apply(Map<String, dynamic>? m) {
    if (m == null) return;
    _milestone = m;
    _note.text = m['note']?.toString() ?? '';
    _weight.text = _numText(m['weight_kg']);
    _height.text = _numText(m['height_cm']);
    _achieved = m['achieved'] == true;
    final raw = m['achieved_at']?.toString();
    _achievedAt = (raw != null && raw.isNotEmpty) ? DateTime.tryParse(raw) : null;
  }

  String _numText(Object? value) {
    if (value == null) return '';
    if (value is num) {
      return value == value.roundToDouble()
          ? '${value.toInt()}'
          : value.toString();
    }
    return value.toString();
  }

  Future<void> _load() async {
    try {
      final m = await ref
          .read(familychatRepositoryProvider)
          .diaryMilestoneDetail(widget.code);
      if (!mounted) return;
      setState(() {
        _apply(m);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _photos {
    final raw = _milestone?['photos'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Future<void> _pickDate() async {
    if (!widget.canEdit) return;
    final initial = _achievedAt ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      _achievedAt = picked;
      _achieved = true;
    });
  }

  Future<void> _save() async {
    if (!widget.canEdit || _saving) return;
    setState(() => _saving = true);
    try {
      final data = <String, dynamic>{
        'achieved': _achieved,
        'note': _note.text.trim(),
        if (_achieved && _achievedAt != null)
          'achieved_at': DateFormat('yyyy-MM-dd').format(_achievedAt!),
        if (!_achieved) 'achieved_at': null,
      };
      final w = double.tryParse(_weight.text.trim().replaceAll(',', '.'));
      final h = double.tryParse(_height.text.trim().replaceAll(',', '.'));
      if (_weight.text.trim().isNotEmpty) data['weight_kg'] = w;
      if (_height.text.trim().isNotEmpty) data['height_cm'] = h;
      final m = await ref
          .read(familychatRepositoryProvider)
          .patchDiaryMilestone(widget.code, data);
      if (!mounted) return;
      setState(() {
        _apply(m);
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сохранено')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _milestone?['title']?.toString() ?? 'Веха';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.canEdit)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Сохранить'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Уже умею'),
                  value: _achieved,
                  onChanged: widget.canEdit
                      ? (v) => setState(() {
                            _achieved = v;
                            if (v && _achievedAt == null) {
                              _achievedAt = DateTime.now();
                            }
                          })
                      : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Когда получилось'),
                  subtitle: Text(
                    _achievedAt == null
                        ? '—'
                        : DateFormat('dd.MM.yyyy').format(_achievedAt!),
                  ),
                  trailing: widget.canEdit
                      ? const Icon(Icons.calendar_today_outlined)
                      : null,
                  onTap: widget.canEdit ? _pickDate : null,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _note,
                  enabled: widget.canEdit,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Заметка',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _weight,
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Вес, кг',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _height,
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Рост, см',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text('Фото', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_photos.isEmpty)
                  const Text('Пока нет фото вехи')
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _photos.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemBuilder: (context, index) {
                      final photo = _photos[index];
                      final url = (photo['file_url'] ??
                              photo['url'] ??
                              '')
                          .toString();
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: url.isEmpty
                            ? ColoredBox(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              )
                            : FamilyPublicImage(url: url, fit: BoxFit.cover),
                      );
                    },
                  ),
              ],
            ),
    );
  }
}
