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
  });

  final int? currentUserId;
  final VoidCallback? onOpenOwnProfile;

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Семья'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Участники'),
            Tab(text: 'Дерево'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _members.length,
                    itemBuilder: (context, i) {
                      final m = _members[i];
                      final name = m['display_name']?.toString() ?? '';
                      final avatarUrl = m['avatar_url']?.toString();
                      final birthday = m['birthday_display']?.toString();
                      final subtitleParts = <String>[
                        if (m['kinship_label'] != null) m['kinship_label']!.toString(),
                        if (birthday != null && birthday.isNotEmpty) birthday,
                      ];
                      return ListTile(
                        leading: ChatAvatar(
                          name: name,
                          avatarUrl: avatarUrl?.isNotEmpty == true ? avatarUrl : null,
                          radius: 22,
                        ),
                        title: Text(name),
                        subtitle: Text(subtitleParts.join(' · ')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openMember(m),
                      );
                    },
                  ),
                ),
          FamilyTreeTab(
            currentUserId: widget.currentUserId,
            onOpenOwnProfile: widget.onOpenOwnProfile,
          ),
        ],
      ),
    );
  }
}
