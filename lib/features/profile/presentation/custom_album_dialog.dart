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
    this.initialAddMode = 'owner',
    this.initialAddUserIds = const [],
    this.albumPk,
  });

  final int userId;
  final String initialTitle;
  final String initialAccessMode;
  final List<int> initialAccessUserIds;
  final String initialAddMode;
  final List<int> initialAddUserIds;
  final int? albumPk;

  static Future<bool?> show(
    BuildContext context, {
    required int userId,
    String initialTitle = '',
    String initialAccessMode = 'all',
    List<int> initialAccessUserIds = const [],
    String initialAddMode = 'owner',
    List<int> initialAddUserIds = const [],
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
          initialAddMode: initialAddMode,
          initialAddUserIds: initialAddUserIds,
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
  late String _addMode;
  late Set<int> _selectedAddUserIds;
  List<Map<String, dynamic>> _members = [];
  bool _loadingMembers = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
    _accessMode = widget.initialAccessMode;
    _selectedUserIds = widget.initialAccessUserIds.toSet();
    _addMode = widget.initialAddMode;
    _selectedAddUserIds = widget.initialAddUserIds.toSet();
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
  bool get _needsAddMembers => _addMode == 'selected';

  List<int> get _selectableMemberIds => _members
      .map((m) {
        final uid = m['user_id'];
        return uid is int ? uid : int.tryParse('$uid');
      })
      .whereType<int>()
      .toList();

  bool get _allMembersSelected {
    final ids = _selectableMemberIds;
    return ids.isNotEmpty && ids.every(_selectedUserIds.contains);
  }

  void _toggleSelectAllMembers() {
    final ids = _selectableMemberIds;
    setState(() {
      if (_allMembersSelected) {
        _selectedUserIds.removeAll(ids);
      } else {
        _selectedUserIds.addAll(ids);
      }
    });
  }

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
    if (_needsAddMembers && _selectedAddUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите, кто может добавлять фото')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final userIds = _needsMembers ? _selectedUserIds.toList() : <int>[];
      final addUserIds = _needsAddMembers ? _selectedAddUserIds.toList() : <int>[];
      if (widget.albumPk != null) {
        await repo.updateCustomGalleryAlbum(
          widget.userId,
          widget.albumPk!,
          title: title,
          accessMode: _accessMode,
          accessUserIds: userIds,
          addMode: _addMode,
          addUserIds: addUserIds,
        );
      } else {
        await repo.createCustomGalleryAlbum(
          widget.userId,
          title: title,
          accessMode: _accessMode,
          accessUserIds: userIds,
          addMode: _addMode,
          addUserIds: addUserIds,
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
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _loadingMembers || _selectableMemberIds.isEmpty
                        ? null
                        : _toggleSelectAllMembers,
                    child: Text(_allMembersSelected ? 'Снять все' : 'Выбрать все'),
                  ),
                ),
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
              const SizedBox(height: 12),
              Text('Кто может добавлять фото',
                  style: Theme.of(context).textTheme.titleSmall),
              RadioListTile<String>(
                value: 'owner',
                groupValue: _addMode,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _addMode = v ?? 'owner'),
                title: const Text('Только создатель'),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<String>(
                value: 'all',
                groupValue: _addMode,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _addMode = v ?? 'all'),
                title: const Text('Все участники семьи'),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<String>(
                value: 'selected',
                groupValue: _addMode,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _addMode = v ?? 'selected'),
                title: const Text('Выбранные участники'),
                contentPadding: EdgeInsets.zero,
              ),
              if (_needsAddMembers) ...[
                const SizedBox(height: 8),
                if (_loadingMembers)
                  const Center(
                      child: Padding(
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
                          value: _selectedAddUserIds.contains(userId),
                          onChanged: _saving
                              ? null
                              : (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedAddUserIds.add(userId);
                                    } else {
                                      _selectedAddUserIds.remove(userId);
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
