import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
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
  bool _loading = true;
  String _query = '';
  String _relationFilter = 'all';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(familychatRepositoryProvider).members();
      if (!mounted) return;
      setState(() {
        _members = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openMember(Map<String, dynamic> member) {
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
    final tabBar = TabBar(
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
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  children: [
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
                        border: const OutlineInputBorder(),
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
