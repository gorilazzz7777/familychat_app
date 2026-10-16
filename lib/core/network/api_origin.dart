import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_http_adapter.dart';

/// MegaFon / RU ISP paths periodically blackhole either
/// `familychat-app.ru:443` or `:4443` (same VPS IP). Race both, sticky-pick,
/// and failover on transport errors so the app backend stays reachable.
abstract final class ApiOrigin {
  static const _prefKey = 'api_origin_v1';
  static const _compileApiBase = String.fromEnvironment(
    'FAMILYCHAT_API_BASE_URL',
    defaultValue: '',
  );
  static const probeTimeout = Duration(milliseconds: 2800);

  /// Prefer :443 first — stream proxies it to the same nginx as :4443.
  /// :4443 remains the alternate when ISP blocks :443.
  static const List<String> candidates = [
    'https://familychat-app.ru',
    'https://familychat-app.ru:4443',
  ];

  static String _current = candidates.first;
  static bool _lockedByCompileDefine = false;
  static bool _ready = false;
  static Future<void>? _inflight;
  static final List<void Function(String origin)> _listeners = [];

  static String get current => _current;

  static bool get isReady => _ready || _lockedByCompileDefine;

  static void addListener(void Function(String origin) listener) {
    _listeners.add(listener);
  }

  static void removeListener(void Function(String origin) listener) {
    _listeners.remove(listener);
  }

  /// Call once near process start (non-blocking OK — races in background).
  static Future<void> ensureReady({bool force = false}) {
    if (_lockedByCompileDefine) {
      _ready = true;
      return Future<void>.value();
    }
    if (!force && _ready && _inflight == null) {
      return Future<void>.value();
    }
    return _inflight ??= _resolve(force: force).whenComplete(() {
      _inflight = null;
    });
  }

  /// After a transport failure on [failedOrigin], switch to the other hop.
  /// Returns true if origin changed.
  static Future<bool> failoverFrom(String failedOrigin) async {
    if (_lockedByCompileDefine) return false;
    final normalized = _normalize(failedOrigin);
    final alt = candidates.firstWhere(
      (c) => c != normalized,
      orElse: () => candidates.first,
    );
    if (alt == _current && normalized != _current) {
      // Already on the other hop.
      return false;
    }
    debugPrint('[ApiOrigin] failover $normalized → probe $alt');
    final ok = await _probe(alt);
    if (ok) {
      await _setCurrent(alt, persist: true);
      _ready = true;
      return true;
    }
    // Full re-race (sticky may be stale both ways).
    await ensureReady(force: true);
    return _current != normalized;
  }

  static Future<void> _resolve({required bool force}) async {
    _applyCompileOverrideIfAny();
    if (_lockedByCompileDefine) return;

    final prefs = await SharedPreferences.getInstance();
    final sticky = prefs.getString(_prefKey);
    final ordered = <String>[];
    if (!force && sticky != null && candidates.contains(sticky)) {
      ordered.add(sticky);
    }
    for (final c in candidates) {
      if (!ordered.contains(c)) ordered.add(c);
    }

    // Quick sticky probe, then race the rest in parallel.
    if (ordered.isNotEmpty) {
      final first = ordered.first;
      if (await _probe(first)) {
        await _setCurrent(first, persist: true);
        _ready = true;
        debugPrint('[ApiOrigin] sticky-hit $first');
        // Background-confirm the other stays optional — skip.
        return;
      }
      debugPrint('[ApiOrigin] sticky-miss $first');
    }

    final winner = await _race(ordered);
    await _setCurrent(winner, persist: true);
    _ready = true;
    debugPrint('[ApiOrigin] race-winner $winner');
  }

  static Future<String> _race(List<String> ordered) async {
    final completer = Completer<String>();
    var pending = ordered.length;
    if (pending == 0) return candidates.first;

    for (final origin in ordered) {
      unawaited(() async {
        final ok = await _probe(origin);
        if (ok && !completer.isCompleted) {
          completer.complete(origin);
        }
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          // Last resort: keep sticky/default even if probes failed (offline).
          completer.complete(ordered.first);
        }
      }());
    }

    try {
      return await completer.future.timeout(
        probeTimeout + const Duration(milliseconds: 400),
      );
    } catch (_) {
      return ordered.first;
    }
  }

  static Future<bool> _probe(String origin) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: probeTimeout,
        receiveTimeout: probeTimeout,
        sendTimeout: probeTimeout,
        // 401/403 mean TLS+TCP reached Django — good enough.
        validateStatus: (code) => code != null && code > 0 && code < 500,
      ),
    );
    configureNativeHttpAdapter(dio);
    try {
      await dio.get<dynamic>('$origin/api/v1/');
      return true;
    } catch (e) {
      debugPrint('[ApiOrigin] probe fail $origin err=$e');
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  static void _applyCompileOverrideIfAny() {
    final raw = _compileApiBase.trim();
    if (raw.isEmpty) return;
    try {
      final uri = Uri.parse(raw);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        _current = uri.origin;
        _lockedByCompileDefine = true;
        _ready = true;
      }
    } catch (_) {}
  }

  static Future<void> _setCurrent(String origin, {required bool persist}) async {
    final next = _normalize(origin);
    final changed = next != _current;
    _current = next;
    if (persist && !_lockedByCompileDefine) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, next);
    }
    if (changed) {
      for (final l in List.of(_listeners)) {
        try {
          l(next);
        } catch (_) {}
      }
    }
  }

  static String _normalize(String originOrBase) {
    final s = originOrBase.trim();
    if (s.isEmpty) return candidates.first;
    try {
      final u = Uri.parse(s.endsWith('/') ? s : '$s/');
      if (u.hasScheme && u.host.isNotEmpty) return u.origin;
    } catch (_) {}
    // Strip path if someone passed full api base.
    for (final c in candidates) {
      if (s.startsWith(c)) return c;
    }
    return s.replaceAll(RegExp(r'/api/v1/?$'), '').replaceAll(RegExp(r'/+$'), '');
  }
}
