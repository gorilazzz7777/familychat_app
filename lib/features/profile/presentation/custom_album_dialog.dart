import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import 'widgets/chat_avatar.dart';

/// Диалог создания или редактирования пользовательского альбома.
class CustomAlbumDialog extends ConsumerStatefulWidget {
  const CustomAlbumDialog({
    super.key,
    required this.userId,
    this.initialTitle = '',
    this.initialAccessMode = 'all',
    this.initialAccessUserIds = const [],
    this.albumPk,
  });

  final int userId;
  final String initialTitle;
  final String initialAccessMode;
  final List<int> initialAccessUserIds;
  final int? albumPk;

  static Future<bool?> show(
    BuildContext context, {
    required int userId,
    String initialTitle = '',
    String initialAccessMode = 'all',
    List<int> initialAccessUserIds = const [],
    int? albumPk,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: CustomAlbumDialog(
          userId: userId,
          initialTitle: initialTitle,
          initialAccessMode: initialAccessMode,
          initialAccessUserIds: initialAccessUserIds,
          albumPk: albumPk,
        ),
      ),
    );
  }

  @override
  ConsumerState<CustomAlbumDialog> createState() => _CustomAlbumDialogState();
}

class _CustomAlbumDialogState extends ConsumerState<CustomAlbumDialog> {
  late final TextEditingController _title;
  late String _accessMode;
  late Set<int> _selectedUserIds;
  List<Map<String, dynamic>> _members = [];
  bool _loadingMembers = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
    _accessMode = widget.initialAccessMode;
    _selectedUserIds = widget.initialAccessUserIds.toSet();
    _loadMembers();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
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

  bool get _needsMembers => _accessMode == 'allow' || _accessMode == 'deny';

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Укажите название альбома')),
      );
      return;
    }
    if (_needsMembers && _selectedUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите участников')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final userIds = _needsMembers ? _selectedUserIds.toList() : <int>[];
      if (widget.albumPk != null) {
        await repo.updateCustomGalleryAlbum(
          widget.userId,
          widget.albumPk!,
          title: title,
          accessMode: _accessMode,
          accessUserIds: userIds,
        );
      } else {
        await repo.createCustomGalleryAlbum(
          widget.userId,
          title: title,
          accessMode: _accessMode,
          accessUserIds: userIds,
        );
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

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.albumPk != null;
    return AlertDialog(
      title: Text(isEdit ? 'Редактировать альбом' : 'Новый альбом'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 16),
              Text('Кому доступен', style: Theme.of(context).textTheme.titleSmall),
              RadioListTile<String>(
                value: 'all',
                groupValue: _accessMode,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _accessMode = v ?? 'all'),
                title: const Text('Всем'),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<String>(
                value: 'allow',
                groupValue: _accessMode,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _accessMode = v ?? 'allow'),
                title: const Text('Только выбранным'),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<String>(
                value: 'deny',
                groupValue: _accessMode,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _accessMode = v ?? 'deny'),
                title: const Text('Всем, кроме выбранных'),
                contentPadding: EdgeInsets.zero,
              ),
              if (_needsMembers) ...[
                const SizedBox(height: 8),
                if (_loadingMembers)
                  const Center(child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ))
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
                          value: _selectedUserIds.contains(userId),
                          onChanged: _saving
                              ? null
                              : (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedUserIds.add(userId);
                                    } else {
                                      _selectedUserIds.remove(userId);
                                    }
                                  });
                                },
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
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(isEdit ? 'Сохранить' : 'Создать'),
        ),
      ],
    );
  }
}
