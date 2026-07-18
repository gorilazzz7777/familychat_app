import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/offline_ui.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/widgets/family_tab_bar.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/presence/user_presence.dart';
import '../../chat/presentation/chat_call_screen.dart';
import '../../chat/presentation/chat_conversation_screen.dart';
import '../../profile/presentation/profile_gallery_tab.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../../profile/presentation/widgets/premium_badges.dart';

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
  ConsumerState<MemberProfileScreen> createState() =>
      _MemberProfileScreenState();
}

class _MemberProfileScreenState extends ConsumerState<MemberProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _openingChat = false;
  bool _openingCall = false;
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
      final data = await ref
          .read(familychatRepositoryProvider)
          .memberProfile(widget.userId);
      if (!mounted) return;
      setState(() {
        _profile = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = OfflineUi.loadErrorMessage(
          e,
          fallback: 'Не удалось загрузить профиль',
        );
      });
    }
  }

  Future<void> _openChat() async {
    if (_openingChat || _openingCall) return;
    setState(() => _openingChat = true);
    try {
      final thread = await ref
          .read(familychatRepositoryProvider)
          .memberDmThread(widget.userId);
      if (!mounted) return;
      final p = _profile;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatConversationScreen(
            threadId: thread['id'] as int,
            title: thread['title']?.toString() ??
                p?['display_name']?.toString() ??
                'Чат',
            defaultTitle: thread['default_title']?.toString() ??
                thread['title']?.toString() ??
                p?['display_name']?.toString() ??
                'Чат',
            customTitle: thread['custom_title']?.toString() ?? '',
            kind: 'dm',
            peerUserId: widget.userId,
            initialPeerAvatarUrl: p?['avatar_url']?.toString().trim(),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть чат: $e')),
      );
    } finally {
      if (mounted) setState(() => _openingChat = false);
    }
  }

  Future<void> _startCall() async {
    if (_openingCall || _openingChat) return;
    setState(() => _openingCall = true);
    try {
      final thread = await ref
          .read(familychatRepositoryProvider)
          .memberDmThread(widget.userId);
      if (!mounted) return;
      final p = _profile;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatCallScreen(
            threadId: thread['id'] as int,
            title: thread['title']?.toString() ??
                p?['display_name']?.toString() ??
                'Чат',
            isCaller: true,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось начать звонок: $e')),
      );
    } finally {
      if (mounted) setState(() => _openingCall = false);
    }
  }

  Future<void> _openAvatarPreview(String avatarUrl, String name) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: FamilyPublicImage(
                  url: avatarUrl,
                  fit: BoxFit.contain,
                  placeholder: const Center(
                    child: CircularProgressIndicator(),
                  ),
                  error: Container(
                    padding: const EdgeInsets.all(24),
                    color: Colors.black54,
                    child: Text(
                      'Не удалось загрузить фото',
                      style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                          ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Закрыть',
              ),
            ),
            Positioned(
              left: 12,
              bottom: 12,
              right: 12,
              child: Text(
                name,
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Профиль участника',
        bottom: _loading || _error != null || _profile == null
            ? null
            : FamilyTabBar.build(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'Основное'),
                  Tab(text: 'Галерея'),
                ],
              ),
      ),
      body: _loading
          ? const DeferredPlaceholder(
              child: Center(child: CircularProgressIndicator()),
            )
          : _error != null
              ? Center(child: Text(_error!))
              : _profile == null
                  ? const SizedBox.shrink()
                  : TabBarView(
                  controller: _tabs,
                  children: [
                    _buildMainTab(Theme.of(context)),
                    ProfileGalleryTab(
                      userId: widget.userId,
                      isOwnGallery: _profile?['is_self'] == true,
                    ),
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
    final status = userPresenceFromProfile(p).label;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        Center(
          child: GestureDetector(
            onTap: avatarUrl?.isNotEmpty == true
                ? () => _openAvatarPreview(avatarUrl!, name)
                : null,
            child: ChatAvatar(
              name: name,
              avatarUrl: avatarUrl?.isNotEmpty == true ? avatarUrl : null,
              radius: 48,
            ),
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
        if (PremiumBadges.labelsFrom(
          p['entitlements'] as Map<String, dynamic>?,
        ).isNotEmpty) ...[
          const SizedBox(height: 8),
          PremiumBadges(
            entitlements: p['entitlements'] as Map<String, dynamic>?,
          ),
        ],
        if (p['kinship_label'] != null || !isSelf) ...[
          const SizedBox(height: 4),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p['kinship_label'] != null)
                  Text(
                    p['kinship_label']?.toString() ?? '',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (!isSelf)
                  Padding(
                    padding: EdgeInsets.only(top: p['kinship_label'] != null ? 2 : 0),
                    child: Text(
                      status,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (!isSelf)
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _openingChat || _openingCall ? null : _openChat,
                  icon: _openingChat
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.chat_outlined),
                  label: Text(_openingChat ? 'Открываю…' : 'Чат'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openingChat || _openingCall ? null : _startCall,
                  icon: _openingCall
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.call_outlined),
                  label: Text(_openingCall ? 'Запуск…' : 'Позвонить'),
                ),
              ),
            ],
          ),
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
