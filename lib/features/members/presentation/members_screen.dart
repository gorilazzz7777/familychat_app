import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_tab_bar.dart';
import '../../chat/data/chat_offline_sync.dart';
import '../../location/presentation/family_map_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'child_profile_screen.dart';
import 'family_invite_flow.dart';
import 'family_tree_tab.dart';
import 'member_profile_screen.dart';

class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({
    super.key,
    required this.currentUserId,
    this.onOpenOwnProfile,
    this.showAppBar = true,
  });

  final int? currentUserId;
  final VoidCallback? onOpenOwnProfile;
  final bool showAppBar;

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _importableBabies = [];
  bool _loading = true;
  bool _importing = false;
  String _query = '';
  String _relationFilter = 'all';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    ChatOfflineSync.instance.addListener(_onOfflineStateChanged);
    _load();
  }

  @override
  void dispose() {
    ChatOfflineSync.instance.removeListener(_onOfflineStateChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onOfflineStateChanged() {
    if (!mounted) return;
    if (ChatOfflineSync.instance.isOnline) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final cached = await FamilyChatLocalCache.readChatMembers();
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() {
        _members = cached;
        _loading = false;
      });
    }

    final repo = ref.read(familychatRepositoryProvider);
    if (_members.isEmpty && mounted) {
      setState(() => _loading = true);
    }
    try {
      final list = await repo.members();
      await FamilyChatLocalCache.saveChatMembers(list);
      var importable = <Map<String, dynamic>>[];
      final hasChild = list.any((m) => m['is_child'] == true);
      if (!hasChild) {
        try {
          importable = await repo.childrenImportable();
        } catch (_) {}
      }
      if (!mounted) return;
      final same = _membersFingerprint(_members) == _membersFingerprint(list);
      if (same && !_loading && importable.length == _importableBabies.length) {
        return;
      }
      setState(() {
        _members = list;
        _importableBabies = importable;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _membersFingerprint(List<Map<String, dynamic>> members) {
    return members
        .map((m) =>
            '${m['user_id']}|${m['child_id']}|${m['display_name']}|${m['avatar_url']}|${m['kinship_label']}|${m['is_online']}')
        .join(';');
  }

  Future<void> _importBaby() async {
    if (_importing) return;
    final adults = _members
        .where((m) => m['is_child'] != true && m['user_id'] is int)
        .toList();
    if (adults.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('В семье нет участников для роли родителей')),
      );
      return;
    }

    final parents = await showDialog<({int? mother, int? father})>(
      context: context,
      builder: (ctx) {
        int? motherUserId;
        int? fatherUserId;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Кто мама и папа?'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _importableBabies.isEmpty
                          ? 'Укажите родителей малыша'
                          : 'Малыш: ${_importableBabies.first['display_name'] ?? 'Малыш'}',
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int?>(
                      value: motherUserId,
                      decoration: const InputDecoration(labelText: 'Мама'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Не указан'),
                        ),
                        for (final m in adults)
                          DropdownMenuItem<int?>(
                            value: m['user_id'] as int,
                            child: Text(
                              m['display_name']?.toString() ?? 'Участник',
                            ),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => motherUserId = v),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int?>(
                      value: fatherUserId,
                      decoration: const InputDecoration(labelText: 'Папа'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Не указан'),
                        ),
                        for (final m in adults)
                          DropdownMenuItem<int?>(
                            value: m['user_id'] as int,
                            child: Text(
                              m['display_name']?.toString() ?? 'Участник',
                            ),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => fatherUserId = v),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    if (motherUserId == null && fatherUserId == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Укажите хотя бы одного родителя'),
                        ),
                      );
                      return;
                    }
                    if (motherUserId != null &&
                        fatherUserId != null &&
                        motherUserId == fatherUserId) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Мама и папа должны быть разными'),
                        ),
                      );
                      return;
                    }
                    Navigator.pop(
                      ctx,
                      (mother: motherUserId, father: fatherUserId),
                    );
                  },
                  child: const Text('Импортировать'),
                ),
              ],
            );
          },
        );
      },
    );
    if (parents == null || !mounted) return;

    setState(() => _importing = true);
    try {
      final child =
          await ref.read(familychatRepositoryProvider).importChildFromDiary(
                motherUserId: parents.mother,
                fatherUserId: parents.father,
              );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${child['display_name'] ?? 'Малыш'} добавлен в семью',
          ),
        ),
      );
      await _load();
      final childId = child['id'] as int? ?? child['child_id'] as int?;
      if (childId != null && mounted) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChildProfileScreen(
              childId: childId,
              initialMember: child,
            ),
          ),
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        final data = e.response?.data;
        String msg = 'Не удалось импортировать малыша из Dairy';
        if (data is Map) {
          final detail = data['detail'];
          if (detail != null) {
            msg = detail.toString();
          } else if (data.isNotEmpty) {
            msg = data.entries
                .map((e) => '${e.key}: ${e.value}')
                .join('; ');
          }
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось импортировать малыша из Dairy'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _openMember(Map<String, dynamic> member) {
    if (member['is_child'] == true) {
      final childId = member['child_id'] as int? ?? member['id'] as int?;
      if (childId == null) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChildProfileScreen(
            childId: childId,
            initialMember: member,
          ),
        ),
      );
      return;
    }
    final userId = member['user_id'] as int?;
    if (userId == null) return;
    if (userId == widget.currentUserId) {
      widget.onOpenOwnProfile?.call();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(
          userId: userId,
          onOpenOwnProfile: widget.onOpenOwnProfile,
        ),
      ),
    );
  }

  String _memberSearchText(Map<String, dynamic> member) {
    final firstName = member['first_name']?.toString() ?? '';
    final lastName = member['last_name']?.toString() ?? '';
    final displayName = member['display_name']?.toString() ?? '';
    final kinshipLabel = member['kinship_label']?.toString() ?? '';
    final kinshipCode = member['kinship_code']?.toString() ?? '';
    return '$displayName $firstName $lastName $kinshipLabel $kinshipCode'
        .toLowerCase();
  }

  bool _matchesRelationFilter(Map<String, dynamic> member) {
    if (_relationFilter == 'all') return true;
    final hay =
        '${member['kinship_label'] ?? ''} ${member['kinship_code'] ?? ''}'
            .toLowerCase();
    switch (_relationFilter) {
      case 'close':
        return hay.contains('мама') ||
            hay.contains('папа') ||
            hay.contains('мать') ||
            hay.contains('отец') ||
            hay.contains('сын') ||
            hay.contains('доч') ||
            hay.contains('ребён') ||
            hay.contains('ребен') ||
            hay.contains('брат') ||
            hay.contains('сестр') ||
            hay.contains('муж') ||
            hay.contains('жена') ||
            hay.contains('mother') ||
            hay.contains('father') ||
            hay.contains('brother') ||
            hay.contains('sister') ||
            hay.contains('son') ||
            hay.contains('daughter') ||
            hay.contains('child') ||
            hay.contains('spouse');
      case 'cousin':
        return hay.contains('двоюр') || hay.contains('cousin');
      case 'parents':
        return hay.contains('мама') ||
            hay.contains('папа') ||
            hay.contains('мать') ||
            hay.contains('отец') ||
            hay.contains('mother') ||
            hay.contains('father') ||
            hay.contains('parent');
      case 'siblings':
        return hay.contains('брат') ||
            hay.contains('сестр') ||
            hay.contains('brother') ||
            hay.contains('sister') ||
            hay.contains('sibling');
      default:
        return true;
    }
  }

  List<Map<String, dynamic>> get _filteredMembers {
    final query = _query.trim().toLowerCase();
    return _members.where((member) {
      if (!_matchesRelationFilter(member)) return false;
      if (query.isEmpty) return true;
      return _memberSearchText(member).contains(query);
    }).toList();
  }

  Widget _relationChip(String id, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _relationFilter == id,
      onSelected: (_) => setState(() => _relationFilter = id),
    );
  }

  Widget _memberTile(Map<String, dynamic> m) {
    final name = m['display_name']?.toString() ?? '';
    final avatarUrl = m['avatar_url']?.toString();
    final birthday = m['birthday_display']?.toString();
    final subtitleParts = <String>[
      if (m['kinship_label'] != null) m['kinship_label']!.toString(),
      if (birthday != null && birthday.isNotEmpty) birthday,
    ];
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ChatAvatar(
            name: name,
            avatarUrl: avatarUrl?.isNotEmpty == true ? avatarUrl : null,
            radius: 22,
          ),
          title: Text(name),
          subtitle: Text(subtitleParts.join(' · ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openMember(m),
        ),
        const Divider(height: 1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabBar = FamilyTabBar.build(
      controller: _tabs,
      tabs: const [
        Tab(text: 'Участники'),
        Tab(text: 'Дерево'),
      ],
    );
    final bodyView = TabBarView(
      controller: _tabs,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _loading
            ? const DeferredPlaceholder(
                child: Center(child: CircularProgressIndicator()),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.map_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: const Text('На карте'),
                      subtitle: const Text('Где сейчас члены семьи'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const FamilyMapScreen(),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    if (_importableBabies.isNotEmpty) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.child_care_outlined,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: const Text('Импортировать малыша из Dairy'),
                        subtitle: Text(
                          _importableBabies.first['display_name']?.toString() ??
                              'Добавить ребёнка в семью',
                        ),
                        trailing: _importing
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: _importing ? null : _importBaby,
                      ),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Поиск',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Очистить',
                                onPressed: () => setState(() => _query = ''),
                                icon: const Icon(Icons.close),
                              ),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _relationChip('all', 'Все'),
                          const SizedBox(width: 8),
                          _relationChip('close', 'Близкие'),
                          const SizedBox(width: 8),
                          _relationChip('parents', 'Родители'),
                          const SizedBox(width: 8),
                          _relationChip('siblings', 'Братья/сестры'),
                          const SizedBox(width: 8),
                          _relationChip('cousin', 'Двоюродные'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_filteredMembers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'Ничего не найдено',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ),
                    for (final m in _filteredMembers) _memberTile(m),
                  ],
                ),
              ),
        FamilyTreeTab(
          currentUserId: widget.currentUserId,
          onOpenOwnProfile: widget.onOpenOwnProfile,
        ),
      ],
    );

    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text('Семья'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.map_outlined),
                  tooltip: 'На карте',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const FamilyMapScreen(),
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.person_add_outlined),
                  tooltip: 'Добавить в семью',
                  onPressed: () => runFamilyInviteFlow(
                    context,
                    ref.read(familychatRepositoryProvider),
                  ),
                ),
              ],
              bottom: tabBar,
            )
          : null,
      body: widget.showAppBar
          ? bodyView
          : Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: tabBar,
                ),
                Expanded(child: bodyView),
              ],
            ),
    );
  }
}
