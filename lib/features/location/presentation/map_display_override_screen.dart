import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/maps/epsg3395.dart';
import '../../../core/maps/yandex_tile_layer.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../chat/data/chat_location_utils.dart';
import '../data/location_share_coordinator.dart';
import '../data/map_display_override_store.dart';

/// Выбор точки и времени, где premium-пользователь показывается на семейной карте.
class MapDisplayOverrideScreen extends ConsumerStatefulWidget {
  const MapDisplayOverrideScreen({super.key});

  @override
  ConsumerState<MapDisplayOverrideScreen> createState() =>
      _MapDisplayOverrideScreenState();
}

class _MapDisplayOverrideScreenState
    extends ConsumerState<MapDisplayOverrideScreen> {
  final _mapController = MapController();
  LatLng? _pickPoint;
  LatLng? _realPoint;
  MapDisplayOverride? _active;
  MapDisplayDurationPreset _preset = MapDisplayDurationPreset.hour1;
  bool _loadingLocation = true;
  bool _saving = false;
  String? _error;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
    _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      unawaited(_refreshActive(silent: true));
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _refreshActive();
    await _loadCurrentLocation();
  }

  Future<void> _refreshActive({bool silent = false}) async {
    final active = await MapDisplayOverrideStore.read();
    if (!mounted) return;
    if (active == null && _active == null) return;
    setState(() {
      _active = active;
      if (active != null) {
        _pickPoint = LatLng(active.latitude, active.longitude);
      }
    });
    if (active != null && _pickPoint != null) {
      try {
        _mapController.move(_pickPoint!, 14);
      } catch (_) {}
    }
  }

  Future<void> _loadCurrentLocation() async {
    setState(() {
      _loadingLocation = true;
      _error = null;
    });
    try {
      final ok = await LocationShareCoordinator.ensurePermission();
      if (!ok) {
        throw StateError('Разрешите доступ к геолокации');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 20),
        ),
      );
      final real = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {
        _realPoint = real;
        _pickPoint ??= real;
        _loadingLocation = false;
      });
      if (_pickPoint != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          try {
            _mapController.move(_pickPoint!, 14);
          } catch (_) {}
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLocation = false;
        _error = e.toString().replaceFirst('StateError: ', '');
        _pickPoint ??= const LatLng(55.751244, 37.618423);
      });
    }
  }

  Future<void> _applyOverride() async {
    final point = _pickPoint;
    if (point == null || _saving) return;
    setState(() => _saving = true);
    try {
      final settings = await ref
          .read(familychatRepositoryProvider)
          .locationSharingSettings();
      if (settings['sharing_enabled'] != true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Сначала включите «Делиться геолокацией с семьёй»',
            ),
          ),
        );
        setState(() => _saving = false);
        return;
      }

      await MapDisplayOverrideStore.set(
        latitude: point.latitude,
        longitude: point.longitude,
        duration: _preset.duration,
      );
      LocationShareCoordinator.instance.attach(
        ref.read(familychatRepositoryProvider),
      );
      await LocationShareCoordinator.instance.pingIfNeeded(force: true);
      if (!mounted) return;
      await _refreshActive();
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Семья увидит выбранную точку ${_preset.label}',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить')),
      );
    }
  }

  Future<void> _clearOverride() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await MapDisplayOverrideStore.clear();
      await LocationShareCoordinator.instance.pingIfNeeded(force: true);
      if (!mounted) return;
      setState(() {
        _active = null;
        _saving = false;
        if (_realPoint != null) _pickPoint = _realPoint;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Показывается реальная геолокация')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
    }
  }

  Future<void> _openInYandex() async {
    final p = _pickPoint;
    if (p == null) return;
    await openChatLocationInYandexMaps(
      ChatLocationPoint(latitude: p.latitude, longitude: p.longitude),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pick = _pickPoint;

    return Scaffold(
      appBar: FamilyAppBar.build(title: 'Где меня показывать'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_active != null)
            Material(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Активно ещё ${formatMapDisplayRemaining(_active!.remaining!)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _saving ? null : _clearOverride,
                      child: const Text('Сбросить'),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Выберите точку на карте и время — семья будет видеть её '
              'вместо вашего текущего местоположения.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _loadingLocation && pick == null
                    ? const Center(child: CircularProgressIndicator())
                    : FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          crs: const Epsg3395(),
                          initialCenter:
                              pick ?? const LatLng(55.751244, 37.618423),
                          initialZoom: 14,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          onTap: (_, latLng) {
                            setState(() => _pickPoint = latLng);
                          },
                        ),
                        children: [
                          const YandexTileLayer(),
                          if (_realPoint != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _realPoint!,
                                  width: 16,
                                  height: 16,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          if (pick != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: pick,
                                  width: 40,
                                  height: 40,
                                  child: const Icon(
                                    Icons.location_on,
                                    color: Colors.red,
                                    size: 40,
                                  ),
                                ),
                              ],
                            ),
                          const YandexMapAttribution(),
                        ],
                      ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Синяя — вы сейчас. Красная — что увидит семья.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Моё местоположение',
                  onPressed: _loadingLocation
                      ? null
                      : () async {
                          await _loadCurrentLocation();
                          if (_realPoint != null) {
                            setState(() => _pickPoint = _realPoint);
                            try {
                              _mapController.move(_realPoint!, 14);
                            } catch (_) {}
                          }
                        },
                  icon: const Icon(Icons.my_location),
                ),
                IconButton(
                  tooltip: 'Открыть в Яндекс.Картах',
                  onPressed: pick == null ? null : _openInYandex,
                  icon: const Icon(Icons.open_in_new),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'На сколько показывать',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final preset in MapDisplayDurationPreset.values)
                  ChoiceChip(
                    label: Text(preset.label),
                    selected: _preset == preset,
                    onSelected: _saving
                        ? null
                        : (v) {
                            if (v) setState(() => _preset = preset);
                          },
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: _saving || pick == null ? null : _applyOverride,
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _active == null ? 'Показывать здесь' : 'Обновить точку',
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
