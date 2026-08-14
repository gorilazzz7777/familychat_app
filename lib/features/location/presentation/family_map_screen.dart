import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/maps/yandex_tile_layer.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/data/chat_location_utils.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import 'location_sharing_settings_screen.dart';

class FamilyMapScreen extends ConsumerStatefulWidget {
  const FamilyMapScreen({super.key, this.focusUserId});

  final int? focusUserId;

  @override
  ConsumerState<FamilyMapScreen> createState() => _FamilyMapScreenState();
}

class _FamilyMapScreenState extends ConsumerState<FamilyMapScreen> {
  final _mapController = MapController();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _members = [];
  int? _selectedUserId;

  @override
  void initState() {
    super.initState();
    _selectedUserId = widget.focusUserId;
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data =
          await ref.read(familychatRepositoryProvider).familyLocationMap();
      final members = (data['members'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _members = members;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitOrFocus());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить карту';
      });
    }
  }

  List<Map<String, dynamic>> get _withPoints {
    return _members.where((m) {
      final loc = m['location'];
      if (loc is! Map) return false;
      return loc['latitude'] != null && loc['longitude'] != null;
    }).toList();
  }

  LatLng? _pointOf(Map<String, dynamic> m) {
    final loc = m['location'];
    if (loc is! Map) return null;
    final lat = loc['latitude'];
    final lng = loc['longitude'];
    final la = lat is num ? lat.toDouble() : double.tryParse('$lat');
    final lo = lng is num ? lng.toDouble() : double.tryParse('$lng');
    if (la == null || lo == null) return null;
    return LatLng(la, lo);
  }

  void _fitOrFocus() {
    if (!_mapController.camera.center.latitude.isFinite) {
      // Map not ready yet.
    }
    final focusId = _selectedUserId ?? widget.focusUserId;
    if (focusId != null) {
      for (final m in _withPoints) {
        final id = m['user_id'];
        final uid = id is int ? id : int.tryParse('$id');
        if (uid == focusId) {
          final p = _pointOf(m);
          if (p != null) {
            _mapController.move(p, 14);
            return;
          }
        }
      }
    }
    final points = _withPoints.map(_pointOf).whereType<LatLng>().toList();
    if (points.isEmpty) {
      _mapController.move(const LatLng(55.751244, 37.618423), 10);
      return;
    }
    if (points.length == 1) {
      _mapController.move(points.first, 14);
      return;
    }
    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final bounds = LatLngBounds(
      LatLng(minLat, minLng),
      LatLng(maxLat, maxLng),
    );
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48)),
    );
  }

  String _agoLabel(Map<String, dynamic> m) {
    final loc = m['location'];
    if (loc is! Map) return 'Нет данных';
    final raw = loc['updated_at']?.toString();
    final dt = raw == null ? null : DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return 'Нет данных';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
    if (diff.inHours < 24) return '${diff.inHours} ч назад';
    return '${diff.inDays} дн назад';
  }

  Future<void> _openInYandex(Map<String, dynamic> m) async {
    final p = _pointOf(m);
    if (p == null) return;
    await openChatLocationInYandexMaps(
      ChatLocationPoint(latitude: p.latitude, longitude: p.longitude),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final withPoints = _withPoints;

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'На карте',
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Кто меня видит',
            onPressed: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const LocationSharingSettingsScreen(),
                ),
              );
              if (mounted) unawaited(_load());
            },
            icon: const Icon(Icons.share_location_outlined),
          ),
        ],
      ),
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
              : Column(
                  children: [
                    Expanded(
                      child: withPoints.isEmpty
                          ? _emptyState(theme)
                          : FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter:
                                    _pointOf(withPoints.first) ??
                                        const LatLng(55.751244, 37.618423),
                                initialZoom: 12,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHighest,
                              ),
                              children: [
                                const YandexTileLayer(),
                                MarkerLayer(
                                  markers: [
                                    for (final m in withPoints)
                                      Marker(
                                        point: _pointOf(m)!,
                                        width: 52,
                                        height: 52,
                                        child: GestureDetector(
                                          onTap: () {
                                            final id = m['user_id'];
                                            final uid = id is int
                                                ? id
                                                : int.tryParse('$id');
                                            setState(
                                              () => _selectedUserId = uid,
                                            );
                                          },
                                          child: _MarkerBubble(
                                            name: m['name']?.toString() ?? '',
                                            avatarUrl:
                                                m['avatar_url']?.toString(),
                                            selected: _selectedUserId ==
                                                (m['user_id'] is int
                                                    ? m['user_id']
                                                    : int.tryParse(
                                                        '${m['user_id']}',
                                                      )),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const YandexMapAttribution(),
                              ],
                            ),
                    ),
                    if (_members.isNotEmpty)
                      SizedBox(
                        height: 112,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          scrollDirection: Axis.horizontal,
                          itemCount: _members.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final m = _members[index];
                            final id = m['user_id'];
                            final uid =
                                id is int ? id : int.tryParse('$id');
                            final selected = uid != null &&
                                uid == _selectedUserId;
                            final hasPoint = _pointOf(m) != null;
                            return GestureDetector(
                              onLongPress:
                                  hasPoint ? () => _openInYandex(m) : null,
                              child: ActionChip(
                              avatar: ChatAvatar(
                                name: m['name']?.toString() ?? '',
                                avatarUrl:
                                    m['avatar_url']?.toString().isNotEmpty ==
                                            true
                                        ? m['avatar_url']?.toString()
                                        : null,
                                radius: 12,
                              ),
                              label: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m['name']?.toString() ?? '',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                  Text(
                                    hasPoint
                                        ? _agoLabel(m)
                                        : 'ожидаем точку',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              onPressed: () {
                                setState(() => _selectedUserId = uid);
                                final p = _pointOf(m);
                                if (p != null) {
                                  _mapController.move(p, 14);
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '${m['name']}: точка ещё не пришла',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.map_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              _members.isEmpty
                  ? 'Пока никто не делится геолокацией с вами'
                  : 'Точки ещё не пришли — подождите обновление',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Попросите родственника включить «Геолокация для семьи» '
              'в настройках профиля.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const LocationSharingSettingsScreen(),
                  ),
                );
              },
              child: const Text('Мои настройки'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkerBubble extends StatelessWidget {
  const _MarkerBubble({
    required this.name,
    required this.avatarUrl,
    required this.selected,
  });

  final String name;
  final String? avatarUrl;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? theme.colorScheme.primary : Colors.white,
          width: selected ? 3 : 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x44000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: ChatAvatar(
        name: name,
        avatarUrl: avatarUrl?.isNotEmpty == true ? avatarUrl : null,
        radius: 22,
      ),
    );
  }
}
