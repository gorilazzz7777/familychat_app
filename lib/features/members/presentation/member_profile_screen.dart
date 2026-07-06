import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../profile/presentation/profile_gallery_tab.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';

String _genderLabel(String gender) {
  return switch (gender) {
    'male' => 'Мужской',
    'female' => 'Женский',
    _ => '—',
  };
}

class MemberProfileScreen extends ConsumerStatefulWidget {
  const MemberProfileScreen({
    super.key,
    required this.userId,
    this.onOpenOwnProfile,
  });

  final int userId;
  final VoidCallback? onOpenOwnProfile;

  @override
  ConsumerState<MemberProfileScreen> createState() => _MemberProfileScreenState();
}

class _MemberProfileScreenState extends ConsumerState<MemberProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Map<String, dynamic>? _profile;
  bool _loading = true;
  String? _error;

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(familychatRepositoryProvider).memberProfile(widget.userId);
      if (!mounted) return;
      setState(() {
        _profile = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль участника'),
        bottom: _loading || _error != null
            ? null
            : TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'Основное'),
                  Tab(text: 'Галерея'),
                ],
              ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _buildMainTab(Theme.of(context)),
                    ProfileGalleryTab(userId: widget.userId),
                  ],
                ),
    );
  }

  Widget _buildMainTab(ThemeData theme) {
    final p = _profile!;
    final isSelf = p['is_self'] == true;
    final name = p['display_name']?.toString() ?? '';
    final avatarUrl = p['avatar_url']?.toString();
    final birthday = p['birthday_display']?.toString();

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        Center(
          child: ChatAvatar(
            name: name,
            avatarUrl: avatarUrl?.isNotEmpty == true ? avatarUrl : null,
            radius: 48,
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            name,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        if (p['kinship_label'] != null) ...[
          const SizedBox(height: 4),
          Center(
            child: Text(
              p['kinship_label']?.toString() ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        _InfoTile(
          icon: Icons.badge_outlined,
          label: 'Имя',
          value: (p['first_name']?.toString() ?? '').isEmpty
              ? '—'
              : p['first_name']!.toString(),
        ),
        _InfoTile(
          icon: Icons.person_outline,
          label: 'Фамилия',
          value: (p['last_name']?.toString() ?? '').isEmpty
              ? '—'
              : p['last_name']!.toString(),
        ),
        _InfoTile(
          icon: Icons.wc_outlined,
          label: 'Пол',
          value: _genderLabel(p['gender']?.toString() ?? ''),
        ),
        _InfoTile(
          icon: Icons.cake_outlined,
          label: 'День рождения',
          value: (birthday == null || birthday.isEmpty) ? '—' : birthday,
        ),
        if (isSelf) ...[
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: widget.onOpenOwnProfile,
            child: const Text('Редактировать в моём профиле'),
          ),
        ],
      ],
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(value, style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
