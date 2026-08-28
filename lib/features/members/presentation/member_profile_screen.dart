import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_error_messages.dart';
import '../../../core/network/offline_ui.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/widgets/family_tab_bar.dart';
import '../../../core/widgets/family_public_image.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/presence/user_presence.dart';
import '../../chat/presentation/chat_call_screen.dart';
import '../../chat/presentation/chat_conversation_screen.dart';
import '../../location/data/location_share_coordinator.dart';
import '../../location/presentation/family_map_screen.dart';
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
  bool _viewerIndividualPremium = false;
  bool _iShareWithThem = false;
  bool _theyShareWithMe = false;
  bool _locationBusy = false;
  bool _removing = false;

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
      final repo = ref.read(familychatRepositoryProvider);
      final results = await Future.wait([
        repo.memberProfile(widget.userId),
        repo.status(),
      ]);
      final data = Map<String, dynamic>.from(results[0] as Map);
      final status = Map<String, dynamic>.from(results[1] as Map);
      final entitlements = status['entitlements'];
      final premium = entitlements is Map &&
          entitlements['individual_premium'] == true;
      var iShare = false;
      var theyShare = false;
      try {
        final sharing = await repo.locationSharingSettings();
        for (final raw in sharing['members'] as List<dynamic>? ?? []) {
          if (raw is! Map) continue;
          final id = raw['user_id'];
          final uid = id is int ? id : int.tryParse('$id');
          if (uid == widget.userId && raw['granted'] == true) {
            iShare = true;
            break;
          }
        }
      } catch (_) {}
      try {
        await repo.memberLocation(widget.userId);
        theyShare = true;
      } catch (_) {
        theyShare = false;
      }
      if (!mounted) return;
      setState(() {
        _profile = data;
        _viewerIndividualPremium = premium;
        _iShareWithThem = iShare;
        _theyShareWithMe = theyShare;
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

  Future<void> _startCall({bool isVideo = false}) async {
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
            isVideo: isVideo,
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

  Future<void> _confirmRemove() async {
    if (_removing) return;
    final name = _profile?['display_name']?.toString() ?? 'участника';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить из семьи?'),
        content: Text(
          '$name больше не будет участником семьи — так же, как если бы вышел сам.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _removing = true);
    try {
      await ref
          .read(familychatRepositoryProvider)
          .removeFamilyMember(widget.userId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _removing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingErrorMessage(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canRemove = _profile?['can_remove'] == true;
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Профиль участника',
        actions: [
          if (canRemove)
            IconButton(
              tooltip: 'Удалить',
              onPressed: _removing ? null : () => unawaited(_confirmRemove()),
              icon: _removing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline),
            ),
        ],
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
    final status = userPresenceFromProfile(
      p,
      preciseLastSeen: _viewerIndividualPremium,
    ).label;

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
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              // Three equal actions + gaps; shrink padding/icon/font on narrow screens.
              final gap = w < 320 ? 6.0 : (w < 360 ? 8.0 : 10.0);
              final iconSize = w < 320 ? 20.0 : (w < 360 ? 22.0 : 24.0);
              final fontSize = w < 320 ? 11.0 : (w < 360 ? 12.0 : 13.0);
              final vPad = w < 320 ? 8.0 : (w < 360 ? 10.0 : 12.0);
              final busy = _openingChat || _openingCall;
              Widget action({
                required VoidCallback? onPressed,
                required IconData icon,
                required String label,
                required bool filled,
                bool showSpinner = false,
              }) {
                final scheme = Theme.of(context).colorScheme;
                final fg = filled
                    ? scheme.onPrimary
                    : (onPressed == null
                        ? scheme.onSurface.withValues(alpha: 0.38)
                        : scheme.primary);
                final child = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showSpinner)
                      SizedBox(
                        width: iconSize,
                        height: iconSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: filled ? Colors.white : null,
                        ),
                      )
                    else
                      Icon(icon, size: iconSize, color: fg),
                    SizedBox(height: w < 320 ? 4 : 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: fontSize,
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                );
                final style = ButtonStyle(
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(vertical: vPad, horizontal: 4),
                  ),
                  minimumSize: const WidgetStatePropertyAll(Size(0, 0)),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
                return Expanded(
                  child: filled
                      ? FilledButton(
                          onPressed: onPressed,
                          style: style,
                          child: child,
                        )
                      : OutlinedButton(
                          onPressed: onPressed,
                          style: style,
                          child: child,
                        ),
                );
              }

              return Row(
                children: [
                  action(
                    onPressed: busy ? null : _openChat,
                    icon: Icons.chat_outlined,
                    label: _openingChat ? '…' : 'Чат',
                    filled: true,
                    showSpinner: _openingChat,
                  ),
                  SizedBox(width: gap),
                  action(
                    onPressed: busy ? null : () => _startCall(),
                    icon: Icons.call_outlined,
                    label: _openingCall ? '…' : 'Звонок',
                    filled: false,
                    showSpinner: _openingCall,
                  ),
                  SizedBox(width: gap),
                  action(
                    onPressed: busy ? null : () => _startCall(isVideo: true),
                    icon: Icons.videocam_outlined,
                    label: 'Видео',
                    filled: false,
                  ),
                ],
              );
            },
          ),
        if (!isSelf) ...[
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _iShareWithThem,
            onChanged: _locationBusy
                ? null
                : (v) async {
                    setState(() => _locationBusy = true);
                    try {
                      if (v) {
                        final ok =
                            await LocationShareCoordinator.ensurePermission(
                          requestAlways: true,
                        );
                        if (!ok && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Нужен доступ к геолокации',
                              ),
                            ),
                          );
                          return;
                        }
                      }
                      await ref
                          .read(familychatRepositoryProvider)
                          .setLocationShareWithMember(
                            userId: widget.userId,
                            granted: v,
                          );
                      if (!mounted) return;
                      setState(() => _iShareWithThem = v);
                      if (v) {
                        LocationShareCoordinator.instance.attach(
                          ref.read(familychatRepositoryProvider),
                        );
                        unawaited(
                          LocationShareCoordinator.instance
                              .pingIfNeeded(force: true),
                        );
                      }
                    } catch (_) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Не удалось изменить доступ'),
                        ),
                      );
                    } finally {
                      if (mounted) setState(() => _locationBusy = false);
                    }
                  },
            title: const Text('Разрешить видеть мою геолокацию'),
            subtitle: const Text('Обновляется раз в 10–15 минут'),
          ),
          if (_theyShareWithMe)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.map_outlined,
                color: theme.colorScheme.primary,
              ),
              title: const Text('На карте'),
              subtitle: const Text('Где сейчас этот человек'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FamilyMapScreen(
                      focusUserId: widget.userId,
                    ),
                  ),
                );
              },
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
