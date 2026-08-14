import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../data/location_share_coordinator.dart';

class LocationSharingSettingsScreen extends ConsumerStatefulWidget {
  const LocationSharingSettingsScreen({super.key});

  @override
  ConsumerState<LocationSharingSettingsScreen> createState() =>
      _LocationSharingSettingsScreenState();
}

class _LocationSharingSettingsScreenState
    extends ConsumerState<LocationSharingSettingsScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<Map<String, dynamic>> _members = [];
  Set<int> _granted = {};
  String? _ownUpdatedAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data =
          await ref.read(familychatRepositoryProvider).locationSharingSettings();
      final members = (data['members'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final granted = <int>{};
      for (final m in members) {
        if (m['granted'] == true) {
          final id = m['user_id'];
          final uid = id is int ? id : int.tryParse('$id');
          if (uid != null) granted.add(uid);
        }
      }
      final own = data['own_location'];
      if (!mounted) return;
      setState(() {
        _members = members;
        _granted = granted;
        _ownUpdatedAt = own is Map ? own['updated_at']?.toString() : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить настройки';
      });
    }
  }

  Future<void> _persist(Set<int> next) async {
    setState(() => _saving = true);
    try {
      if (next.isNotEmpty) {
        final ok = await LocationShareCoordinator.ensurePermission(
          requestAlways: true,
        );
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Разрешите доступ к геолокации, чтобы семья видела, где вы',
              ),
            ),
          );
          setState(() => _saving = false);
          return;
        }
      }
      final data = await ref
          .read(familychatRepositoryProvider)
          .setLocationSharingViewers(next.toList()..sort());
      final members = (data['members'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final granted = <int>{};
      for (final m in members) {
        if (m['granted'] == true) {
          final id = m['user_id'];
          final uid = id is int ? id : int.tryParse('$id');
          if (uid != null) granted.add(uid);
        }
      }
      if (!mounted) return;
      setState(() {
        _members = members;
        _granted = granted;
        _saving = false;
      });
      if (granted.isNotEmpty) {
        LocationShareCoordinator.instance.attach(
          ref.read(familychatRepositoryProvider),
        );
        unawaited(LocationShareCoordinator.instance.pingIfNeeded(force: true));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить')),
      );
    }
  }

  Future<void> _toggleMaster(bool enabled) async {
    if (!enabled) {
      await _persist({});
      return;
    }
    if (_members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('В семье пока нет других участников')),
      );
      return;
    }
    await _persist({
      for (final m in _members)
        if (m['user_id'] is int)
          m['user_id'] as int
        else if (int.tryParse('${m['user_id']}') != null)
          int.parse('${m['user_id']}'),
    });
  }

  Future<void> _toggleMember(int userId, bool granted) async {
    final next = Set<int>.from(_granted);
    if (granted) {
      next.add(userId);
    } else {
      next.remove(userId);
    }
    await _persist(next);
  }

  String _formatUpdated(String? iso) {
    if (iso == null || iso.isEmpty) return 'Ещё не отправлялась';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return 'Ещё не отправлялась';
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return 'Последнее обновление $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = _granted.isNotEmpty;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Геолокация для семьи'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _load,
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: enabled,
                      onChanged: _saving || kIsWeb ? null : _toggleMaster,
                      title: const Text('Делиться геолокацией с семьёй'),
                      subtitle: Text(
                        kIsWeb
                            ? 'На web шаринг недоступен — откройте приложение'
                            : 'Обновляется примерно раз в 10–15 минут. '
                                'Можно выключить в любой момент.',
                      ),
                    ),
                    if (enabled) ...[
                      const SizedBox(height: 4),
                      Text(
                        _formatUpdated(_ownUpdatedAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (!kIsWeb) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _saving
                              ? null
                              : () async {
                                  final ok = await LocationShareCoordinator
                                      .ensurePermission(requestAlways: true);
                                  if (!mounted) return;
                                  if (!ok) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Разрешите геолокацию в настройках системы',
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  await Geolocator.openAppSettings();
                                },
                          icon: const Icon(Icons.my_location_outlined),
                          label: const Text('Разрешить доступ «Всегда»'),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        'Кто может видеть, где я',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      for (final m in _members)
                        _memberTile(m, enabled: !_saving),
                    ],
                  ],
                ),
    );
  }

  Widget _memberTile(Map<String, dynamic> m, {required bool enabled}) {
    final id = m['user_id'];
    final userId = id is int ? id : int.tryParse('$id');
    if (userId == null) return const SizedBox.shrink();
    final name = m['name']?.toString() ?? '';
    final avatar = m['avatar_url']?.toString();
    final granted = _granted.contains(userId);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      value: granted,
      onChanged: enabled ? (v) => _toggleMember(userId, v == true) : null,
      secondary: ChatAvatar(
        name: name,
        avatarUrl: avatar?.isNotEmpty == true ? avatar : null,
        radius: 20,
      ),
      title: Text(name),
      controlAffinity: ListTileControlAffinity.trailing,
    );
  }
}
