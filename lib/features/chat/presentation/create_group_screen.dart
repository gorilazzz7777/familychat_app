import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _title = TextEditingController();
  List<Map<String, dynamic>> _members = [];
  final Set<int> _selected = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final status = await repo.status();
      final myId = status['user_id'] as int?;
      final list = await repo.members();
      if (!mounted) return;
      setState(() {
        _members = list.where((m) => m['user_id'] != myId).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final name = _title.text.trim();
    if (name.isEmpty || _selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Укажите название и участников')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final thread = await ref.read(familychatRepositoryProvider).createGroupChat(
            title: name,
            memberUserIds: _selected.toList(),
          );
      if (!mounted) return;
      Navigator.pop(context, thread);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  List<int> get _selectableMemberIds =>
      _members.map((m) => m['user_id'] as int).toList();

  bool get _allMembersSelected {
    final ids = _selectableMemberIds;
    return ids.isNotEmpty && ids.every(_selected.contains);
  }

  void _toggleSelectAllMembers() {
    final ids = _selectableMemberIds;
    setState(() {
      if (_allMembersSelected) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Новая группа',
        actions: [
          if (!_loading && _members.isNotEmpty)
            TextButton(
              onPressed: _toggleSelectAllMembers,
              child: Text(_allMembersSelected ? 'Снять все' : 'Выбрать все'),
            ),
        ],
      ),
      body: _loading
          ? const DeferredPlaceholder(
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: 'Название группы',
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Участники'),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _members.length,
                    itemBuilder: (context, i) {
                      final m = _members[i];
                      final uid = m['user_id'] as int;
                      final name = m['display_name']?.toString() ?? '';
                      return CheckboxListTile(
                        value: _selected.contains(uid),
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(uid);
                            } else {
                              _selected.remove(uid);
                            }
                          });
                        },
                        title: Text(name),
                        subtitle: Text(m['kinship_label']?.toString() ?? ''),
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed: _saving ? null : _create,
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Создать'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
