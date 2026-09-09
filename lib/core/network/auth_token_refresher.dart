import 'dart:async';

import 'package:dio/dio.dart';

import '../impersonation/impersonation_storage.dart';
import '../session/auth_session_bus.dart';
import '../storage/device_id_storage.dart';
import '../storage/token_storage.dart';
import 'jwt_access_token.dart';

const String kAuthRefreshPath = 'auth/refresh/';
const String kAuthDeviceAuthPath = 'auth/device-auth/';

/// One coordinated JWT refresh for the whole app: timer + in-flight + request path.
class AuthTokenRefresher {
  AuthTokenRefresher({
    required TokenStorage tokenStorage,
    required Dio refreshDio,
  })  : _tokenStorage = tokenStorage,
        _refreshDio = refreshDio;

  final TokenStorage _tokenStorage;
  final Dio _refreshDio;

  static Future<String?>? _inFlight;
  Timer? _timer;
  bool _timersEnabled = false;

  /// Refresh now if the access token is missing, expired, or inside the leeway.
  Future<String?> ensureAccess({bool force = false}) async {
    final existing = _inFlight;
    if (existing != null) {
      try {
        final restored = await existing;
        if (restored != null && restored.isNotEmpty) return restored;
      } catch (_) {}
    }

    if (!force) {
      final token = await _tokenStorage.readAccess();
      if (token != null &&
          token.isNotEmpty &&
          !jwtAccessTokenNeedsProactiveRefresh(token)) {
        _maybeArm(token);
        return token;
      }
    }

    return _coordinate(() => _restoreAccessBody(force: force));
  }

  /// Arm the next refresh from JWT `exp` (or a fallback interval).
  void armFromAccess(String access) {
    _timersEnabled = true;
    _schedule(access);
  }

  void cancel() {
    _timersEnabled = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<String?> startWatching() {
    _timersEnabled = true;
    return ensureAccess();
  }

  Future<String?> _coordinate(Future<String?> Function() body) {
    final existing = _inFlight;
    if (existing != null) return existing;

    late final Future<String?> future;
    future = body().whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
    _inFlight = future;
    return future;
  }

  Future<String?> _restoreAccessBody({bool force = false}) async {
    if (!force) {
      final token = await _tokenStorage.readAccess();
      if (token != null &&
          token.isNotEmpty &&
          !jwtAccessTokenNeedsProactiveRefresh(token)) {
        _maybeArm(token);
        return token;
      }
    }

    final refresh = await _tokenStorage.readRefresh();
    if (refresh != null && refresh.isNotEmpty) {
      final refreshed = await _performRefresh(refresh);
      if (refreshed != null && refreshed.isNotEmpty) {
        _maybeArm(refreshed);
        return refreshed;
      }
    }

    final viaDevice = await _performDeviceAuth();
    if (viaDevice != null && viaDevice.isNotEmpty) {
      _maybeArm(viaDevice);
      return viaDevice;
    }

    if (!force) {
      final token = await _tokenStorage.readAccess();
      if (token != null &&
          token.isNotEmpty &&
          !jwtAccessTokenNeedsProactiveRefresh(token)) {
        _maybeArm(token);
        return token;
      }
    }

    final stillHasRefresh = await _tokenStorage.hasRefreshCredential();
    if (stillHasRefresh && _timersEnabled) {
      _armTimer(const Duration(seconds: 25));
    } else if (!stillHasRefresh) {
      cancel();
    }
    return null;
  }

  Future<String?> _performRefresh(String refreshToken) async {
    try {
      final response = await _refreshDio.post<Map<String, dynamic>>(
        kAuthRefreshPath,
        data: {'refresh': refreshToken},
      );
      return _applyRefreshResponse(response.data);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _performDeviceAuth() async {
    if (await ImpersonationStorage().isActive()) return null;
    final deviceId = await DeviceIdStorage.peek();
    if (deviceId == null || deviceId.length < 8) return null;
    try {
      final response = await _refreshDio.post<Map<String, dynamic>>(
        kAuthDeviceAuthPath,
        data: {'device_id': deviceId},
      );
      return _applyRefreshResponse(response.data);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _applyRefreshResponse(Map<String, dynamic>? data) async {
    if (data == null) return null;
    final access = data['access'] as String?;
    if (access == null || access.isEmpty) return null;
    final refresh = data['refresh'] as String?;
    if (refresh != null && refresh.isNotEmpty) {
      await _tokenStorage.saveTokens(access: access, refresh: refresh);
    } else {
      await _tokenStorage.saveAccess(access);
    }
    AuthSessionBus.instance.emitAccessRefreshed(access);
    return access;
  }

  void _maybeArm(String access) {
    if (_timersEnabled) _schedule(access);
  }

  void _schedule(String access) {
    if (access.isEmpty) {
      cancel();
      return;
    }
    _armTimer(jwtAccessTokenProactiveWait(access));
  }

  void _armTimer(Duration wait) {
    _timer?.cancel();
    final delay = wait <= Duration.zero ? const Duration(milliseconds: 80) : wait;
    _timer = Timer(delay, () {
      unawaited(ensureAccess());
    });
  }
}
