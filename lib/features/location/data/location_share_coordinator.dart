import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/familychat/data/familychat_repository.dart';

/// Периодическая отправка геолокации, пока пользователь кому-то шарит.
///
/// Пока приложение живо: раз в ~12 минут и при возврате на передний план.
/// Для фона ОС всё равно нужна «всегда»-геолокация — запрашиваем в настройках.
class LocationShareCoordinator with WidgetsBindingObserver {
  LocationShareCoordinator._();
  static final LocationShareCoordinator instance = LocationShareCoordinator._();

  static const _prefsLastPing = 'fc_location_last_ping_ms';
  static const interval = Duration(minutes: 12);
  static const staleAfter = Duration(minutes: 10);

  FamilychatRepository? _repo;
  Timer? _timer;
  bool _busy = false;
  bool _observing = false;

  void attach(FamilychatRepository repo) {
    _repo = repo;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(pingIfNeeded()));
    unawaited(pingIfNeeded(force: true));
  }

  void detach() {
    _timer?.cancel();
    _timer = null;
    _repo = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(pingIfNeeded());
    }
  }

  Future<void> pingIfNeeded({bool force = false}) async {
    final repo = _repo;
    if (repo == null || kIsWeb) return;
    if (_busy) return;
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_prefsLastPing) ?? 0;
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (!force && DateTime.now().difference(last) < staleAfter) {
        return;
      }

      Map<String, dynamic> settings;
      try {
        settings = await repo.locationSharingSettings();
      } catch (_) {
        return;
      }
      if (settings['sharing_enabled'] != true) return;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 25),
        ),
      );
      await repo.pingLocation(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracyM: pos.accuracy,
      );
      await prefs.setInt(
        _prefsLastPing,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('location ping failed: $e');
      }
    } finally {
      _busy = false;
    }
  }

  static Future<bool> ensurePermission({bool requestAlways = false}) async {
    if (kIsWeb) return false;
    final service = await Geolocator.isLocationServiceEnabled();
    if (!service) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }
    if (requestAlways &&
        permission == LocationPermission.whileInUse) {
      // На Android 10+ отдельный диалог «всегда» через permission_handler
      // удобнее; geolocator.requestPermission повторно может предложить Always.
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }
}
