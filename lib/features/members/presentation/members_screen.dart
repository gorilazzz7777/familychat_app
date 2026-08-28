import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../../core/presence/user_presence.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_tab_bar.dart';
import '../../chat/data/chat_local_reads.dart';
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
  bool _viewerIndividualPremium = false;
  String _query = '';
  StreamSubscription<List<Map<String, dynamic>>>? _membersSub;
  int _loadGen = 0;
  Future<void>? _networkRefreshInFlight;
  bool _lastKnownOnline = true;

  bool get _useLocalWatch => ChatLocalStore.isSupported;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    ChatOfflineSync.instance.addListener(_onOfflineStateChanged);
    _lastKnownOnline = ChatOfflineSync.instance.isOnline;
    if (_useLocalWatch) {
      _bindLocalMembers();
      unawaited(_refreshFromNetwork());
    } else {
      unawaited(_loadHybrid());
    }
  }

  @override
  void dispose() {
    ChatOfflineSync.instance.removeListener(_onOfflineStateChanged);
    unawaited(_membersSub?.cancel() ?? Future<void>.value());
    _tabs.dispose();
    super.dispose();
  }

  void _bindLocalMembers() {
    _membersSub = ChatLocalStore.instance.watchMembers().listen((members) {
      if (!mounted) return;
      if (_membersFingerprint(_members) == _membersFingerprint(members) &&
          !_loading) {
        return;
      }
      setState(() {
        _members = members;
        if (members.isNotEmpty) {
          _loading = false;
        }
      });
    });
  }

  void _onOfflineStateChanged() {
    if (!mounted) return;
    final online = ChatOfflineSync.instance.isOnline;
    final becameOnline = online && !_lastKnownOnline;
    _lastKnownOnline = online;
    if (becameOnline) {
      unawaited(_refreshFromNetwork());
    }
  }

  Future<void> _load() => _useLocalWatch ? _refreshFromNetwork() : _loadHybrid();

  Future<void> _refreshFromNetwork() async {
    if (_networkRefreshInFlight != null) {
      return _networkRefreshInFlight!;
    }
    final future = _refreshFromNetworkBody();
    _networkRefreshInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_networkRefreshInFlight, future)) {
        _networkRefreshInFlight = null;
      }
    }
  }

  Future<void> _refreshFromNetworkBody() async {
    final gen = ++_loadGen;
    final repo = ref.read(familychatRepositoryProvider);
    if (_members.isEmpty && mounted) {
      setState(() => _loading = true);
    }
    try {
      final list = await repo.members();
      if (gen != _loadGen || !mounted) return;

      await ChatLocalReads.saveMembers(list);

      var importable = _importableBabies;
      final hasChild = list.any((m) => m['is_child'] == true);
      if (hasChild) {
        importable = const [];
      } else {
        try {
          importable = await repo.childrenImportable();
        } catch (_) {}
      }
      if (gen != _loadGen || !mounted) return;

      var premium = _viewerIndividualPremium;
      for (final m in list) {
        if (m['user_id'] == widget.currentUserId) {
          final entitlements = m['entitlements'];
          if (entitlements is Map) {
            premium = entitlements['individual_premium'] == true;
          }
          break;
        }
      }

      if (!_useLocalWatch) {
        final sameMembers =
            _membersFingerprint(_members) == _membersFingerprint(list);
        if (!sameMembers || _loading) {
          setState(() {
            _members = list;
            _loading = false;
          });
        }
      }

      final importableChanged =
          _importableFingerprint(importable) !=
              _importableFingerprint(_importableBabies);
      if (importableChanged ||
          premium != _viewerIndividualPremium ||
          _loading) {
        setState(() {
          _importableBabies = importable;
          _viewerIndividualPremium = premium;
          _loading = false;
        });
      }
    } catch (_) {
      if (gen != _loadGen || !mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Web: cache + network (no SQLite watch).
  Future<void> _loadHybrid() async {
    final gen = ++_loadGen;
    final cached = await ChatLocalReads.members();
    if (gen != _loadGen || !mounted) return;
    if (cached.isNotEmpty) {
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
      if (gen != _loadGen || !mounted) return;
      await ChatLocalReads.saveMembers(list);

      var importable = _importableBabies;
      final hasChild = list.any((m) => m['is_child'] == true);
      if (hasChild) {
        importable = const [];
      } else {
        try {
          importable = await repo.childrenImportable();
        } catch (_) {}
      }
      if (gen != _loadGen || !mounted) return;

      var premium = _viewerIndividualPremium;
      for (final m in list) {
        if (m['user_id'] == widget.currentUserId) {
          final entitlements = m['entitlements'];
          if (entitlements is Map) {
            premium = entitlements['individual_premium'] == true;
          }
          break;
        }
      }

      final sameMembers =
          _membersFingerprint(_members) == _membersFingerprint(list);
      final importableChanged =
          _importableFingerprint(importable) !=
              _importableFingerprint(_importableBabies);
      if (sameMembers &&
          !importableChanged &&
          premium == _viewerIndividualPremium &&
          !_loading) {
        return;
      }
      setState(() {
        _members = list;
        _importableBabies = importable;
        _viewerIndividualPremium = premium;
        _loading = false;
      });
    } catch (_) {
      if (gen != _loadGen || !mounted) return;
      setState(() => _loading = false);
    }
  }

  String _membersFingerprint(List<Map<String, dynamic>> members) {
    return members
        .map((m) =>
            '${m['user_id']}|${m['child_id']}|${m['display_name']}|${m['avatar_url']}|${m['kinship_label']}|${m['is_online']}|${m['last_seen']}|${m['is_child']}')
        .join(';');
  }

  String _importableFingerprint(List<Map<String, dynamic>> babies) {
    return babies
        .map((b) =>
            '${b['id']}|${b['child_id']}|${b['display_name']}|${b['birthday_display']}')
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

  List<Map<String, dynamic>> get _filteredMembers {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _members;
    return _members
        .where((member) => _memberSearchText(member).contains(query))
        .toList();
  }

  String _memberSubtitle(Map<String, dynamic> m) {
    final kinship = m['kinship_label']?.toString().trim() ?? '';
    final isChild = m['is_child'] == true;
    final secondary = isChild
        ? (m['birthday_display']?.toString().trim() ?? '')
        : userPresenceFromProfile(
            m,
            preciseLastSeen: _viewerIndividualPremium,
          ).label;
    final parts = <String>[
      if (kinship.isNotEmpty) kinship,
      if (secondary.isNotEmpty) secondary,
    ];
    return parts.join(' · ');
  }

  Widget _memberTile(Map<String, dynamic> m) {
    final name = m['display_name']?.toString() ?? '';
    final avatarUrl = m['avatar_url']?.toString();
    final subtitle = _memberSubtitle(m);
    final online = m['is_child'] != true && m['is_online'] == true;
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
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  style: online
                      ? TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                ),
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
                FamilyAddMenuButton(
                  repo: ref.read(familychatRepositoryProvider),
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
