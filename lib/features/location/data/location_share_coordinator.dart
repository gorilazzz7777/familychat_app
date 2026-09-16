import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../familychat/data/familychat_repository.dart';
import 'map_display_override_store.dart';

/// Периодическая и фоновая отправка геолокации, пока пользователь кому-то шарит.
///
/// Требует разрешение **Always**. На Android держит location FGS с постоянным
/// уведомлением; на iOS — background location updates + индикатор в статус-баре.
///
/// Обновления: ~раз в 12 минут и при смещении ≥ [moveThresholdM] (не чаще
/// чем раз в [minPingGap]).
class LocationShareCoordinator with WidgetsBindingObserver {
  LocationShareCoordinator._();
  static final LocationShareCoordinator instance = LocationShareCoordinator._();

  static const _prefsLastPing = 'fc_location_last_ping_ms';
  static const interval = Duration(minutes: 12);
  static const staleAfter = Duration(minutes: 10);
  static const minPingGap = Duration(minutes: 3);
  static const moveThresholdM = 400.0;

  FamilyChatRepository? _repo;
  Timer? _timer;
  StreamSubscription<Position>? _positionSub;
  bool _busy = false;
  bool _observing = false;
  bool _trackingDesired = false;
  DateTime? _lastPingAt;
  double? _lastPingLat;
  double? _lastPingLng;

  void attach(FamilyChatRepository repo) {
    _repo = repo;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(pingIfNeeded()));
    unawaited(refreshTracking(forcePing: true));
  }

  void detach() {
    _timer?.cancel();
    _timer = null;
    unawaited(_stopPositionStream());
    _repo = null;
    _trackingDesired = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshTracking());
      unawaited(pingIfNeeded());
    }
  }

  /// Перечитывает настройки шаринга и стартует/останавливает фоновый трекинг.
  Future<void> refreshTracking({bool forcePing = false}) async {
    final repo = _repo;
    if (repo == null || kIsWeb) {
      await _stopPositionStream();
      return;
    }
    var sharing = false;
    try {
      final settings = await repo.locationSharingSettings();
      sharing = settings['sharing_enabled'] == true;
    } catch (_) {
      // Keep previous stream if network fails briefly.
      if (_positionSub != null) return;
      return;
    }
    _trackingDesired = sharing;
    if (!sharing) {
      await _stopPositionStream();
      return;
    }
    final always = await hasAlwaysPermission();
    if (!always) {
      await _stopPositionStream();
      return;
    }
    await _startPositionStream();
    if (forcePing) {
      await pingIfNeeded(force: true);
    }
  }

  Future<void> pingIfNeeded({bool force = false}) async {
    final repo = _repo;
    if (repo == null || kIsWeb) return;
    if (_busy) return;
    _busy = true;
    try {
      if (!force) {
        final prefs = await SharedPreferences.getInstance();
        final lastMs = prefs.getInt(_prefsLastPing) ?? 0;
        final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
        if (DateTime.now().difference(last) < staleAfter) {
          return;
        }
      }

      Map<String, dynamic> settings;
      try {
        settings = await repo.locationSharingSettings();
      } catch (_) {
        return;
      }
      if (settings['sharing_enabled'] != true) {
        await _stopPositionStream();
        return;
      }

      if (!await hasAlwaysPermission()) {
        await _stopPositionStream();
        return;
      }
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      final override = await MapDisplayOverrideStore.read(repo);
      if (override != null && override.isActive) {
        await _sendPing(
          latitude: override.latitude,
          longitude: override.longitude,
          accuracyM: 50,
        );
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 25),
        ),
      );
      await _sendPing(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracyM: pos.accuracy,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('location ping failed: $e');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _sendPing({
    required double latitude,
    required double longitude,
    double? accuracyM,
  }) async {
    final repo = _repo;
    if (repo == null) return;
    await repo.pingLocation(
      latitude: latitude,
      longitude: longitude,
      accuracyM: accuracyM,
    );
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    await prefs.setInt(_prefsLastPing, now.millisecondsSinceEpoch);
    _lastPingAt = now;
    _lastPingLat = latitude;
    _lastPingLng = longitude;
  }

  Future<void> _onStreamPosition(Position pos) async {
    if (!_trackingDesired || _busy) return;
    final now = DateTime.now();
    final lastAt = _lastPingAt;
    if (lastAt != null) {
      final elapsed = now.difference(lastAt);
      if (elapsed < minPingGap) return;
      final moved = _lastPingLat == null || _lastPingLng == null
          ? true
          : Geolocator.distanceBetween(
                _lastPingLat!,
                _lastPingLng!,
                pos.latitude,
                pos.longitude,
              ) >=
              moveThresholdM;
      if (!moved && elapsed < interval) return;
      if (moved && elapsed < minPingGap) return;
    }
    if (_busy) return;
    _busy = true;
    try {
      final repo = _repo;
      if (repo == null) return;
      final override = await MapDisplayOverrideStore.read(repo);
      if (override != null && override.isActive) {
        await _sendPing(
          latitude: override.latitude,
          longitude: override.longitude,
          accuracyM: 50,
        );
        return;
      }
      await _sendPing(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracyM: pos.accuracy,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('location stream ping failed: $e');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _startPositionStream() async {
    if (kIsWeb) return;
    if (_positionSub != null) return;
    try {
      final stream = Geolocator.getPositionStream(
        locationSettings: _backgroundLocationSettings(),
      );
      _positionSub = stream.listen(
        (pos) => unawaited(_onStreamPosition(pos)),
        onError: (Object e) {
          if (kDebugMode) {
            debugPrint('location stream error: $e');
          }
        },
        cancelOnError: false,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('location stream start failed: $e');
      }
    }
  }

  Future<void> _stopPositionStream() async {
    final sub = _positionSub;
    _positionSub = null;
    await sub?.cancel();
  }

  static LocationSettings _backgroundLocationSettings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: moveThresholdM.round(),
        intervalDuration: interval,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Геолокация с семьёй',
          notificationText:
              'Family Space обновляет ваше местоположение для близких',
          notificationChannelName: 'Геолокация с семьёй',
          enableWakeLock: true,
          setOngoing: true,
          notificationIcon: AndroidResource(
            name: 'ic_launcher',
            defType: 'mipmap',
          ),
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.medium,
        activityType: ActivityType.other,
        distanceFilter: moveThresholdM.round(),
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 400,
    );
  }

  static Future<bool> hasAlwaysPermission() async {
    if (kIsWeb) return false;
    final geo = await Geolocator.checkPermission();
    if (geo == LocationPermission.always) return true;
    // Android 10+: permission_handler may report Always separately.
    final always = await Permission.locationAlways.status;
    return always.isGranted;
  }

  /// [requireAlways] — для семейного шаринга (политика A).
  /// Без флага достаточно whileInUse (чат / разовые сценарии).
  static Future<bool> ensurePermission({
    bool requireAlways = false,
    bool openSettingsIfDenied = false,
  }) async {
    if (kIsWeb) return false;
    final service = await Geolocator.isLocationServiceEnabled();
    if (!service) {
      if (openSettingsIfDenied) {
        await Geolocator.openLocationSettings();
      }
      return false;
    }

    // Step 1: when-in-use (required before Always on both platforms).
    var whenInUse = await Permission.locationWhenInUse.status;
    if (!whenInUse.isGranted) {
      whenInUse = await Permission.locationWhenInUse.request();
    }
    if (!whenInUse.isGranted) {
      if (openSettingsIfDenied && whenInUse.isPermanentlyDenied) {
        await openAppSettings();
      }
      return false;
    }

    if (!requireAlways) {
      final geo = await Geolocator.checkPermission();
      return geo == LocationPermission.whileInUse ||
          geo == LocationPermission.always;
    }

    // Step 2: Always (separate system UI on Android 10+ / iOS upgrade).
    var always = await Permission.locationAlways.status;
    if (!always.isGranted) {
      always = await Permission.locationAlways.request();
    }

    // Geolocator may still report whileInUse until process refreshes status.
    var geo = await Geolocator.checkPermission();
    if (geo == LocationPermission.whileInUse) {
      // Second geolocator request sometimes upgrades on iOS.
      geo = await Geolocator.requestPermission();
    }

    final ok = geo == LocationPermission.always || always.isGranted;
    if (!ok && openSettingsIfDenied) {
      await openAppSettings();
    }
    return ok;
  }
}
