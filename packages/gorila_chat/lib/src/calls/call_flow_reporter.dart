import 'dart:async';

import 'package:flutter/widgets.dart';

/// Best-effort call-flow timeline reporter.
///
/// Upload failures are swallowed — never surface to UI / never rethrow.
class CallFlowReporter with WidgetsBindingObserver {
  CallFlowReporter({
    required this.upload,
    this.platform = '',
    this.appVersion = '',
    this.flushInterval = const Duration(seconds: 6),
    this.batchSize = 15,
  });

  /// Uploads a body `{ platform, app_version, events: [...] }`. Must not throw
  /// in a way that breaks callers — this class already wraps in try/catch.
  final Future<void> Function(int callId, Map<String, dynamic> body) upload;

  final String platform;
  final String appVersion;
  final Duration flushInterval;
  final int batchSize;

  int? _callId;
  String _role = '';
  int _seq = 0;
  final List<Map<String, dynamic>> _pending = <Map<String, dynamic>>[];
  Timer? _timer;
  bool _flushing = false;
  bool _disposed = false;
  bool _observing = false;

  int? get callId => _callId;

  void start({required int callId, required String role}) {
    if (_disposed) return;
    _callId = callId;
    _role = role;
    _ensureObserver();
    _ensureTimer();
    log('call_start', data: {'role': role});
  }

  void log(String event, {Map<String, dynamic>? data}) {
    if (_disposed || _callId == null) return;
    final scrubbed = <String, dynamic>{};
    if (data != null) {
      var i = 0;
      for (final entry in data.entries) {
        if (i++ >= 20) break;
        final key = entry.key.length > 40 ? entry.key.substring(0, 40) : entry.key;
        final v = entry.value;
        if (v == null || v is num || v is bool) {
          scrubbed[key] = v;
        } else {
          final s = '$v';
          scrubbed[key] = s.length > 200 ? s.substring(0, 200) : s;
        }
      }
    }
    if (_role.isNotEmpty) {
      scrubbed.putIfAbsent('role', () => _role);
    }
    _seq += 1;
    _pending.add({
      'seq': _seq,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'data': scrubbed,
    });
    if (_pending.length >= batchSize) {
      unawaited(flush());
    }
  }

  Future<void> flush({String reason = 'flush'}) async {
    if (_disposed || _callId == null || _flushing) return;
    if (_pending.isEmpty) return;
    _flushing = true;
    final callId = _callId!;
    final batch = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    try {
      await upload(callId, {
        'platform': platform,
        'app_version': appVersion,
        'events': batch,
      });
    } catch (e, st) {
      // Re-queue so a later flush can retry (cap to avoid unbounded growth).
      if (_pending.length < 500) {
        _pending.insertAll(0, batch);
      }
      debugPrint('CallFlowReporter upload failed ($reason): $e\n$st');
    } finally {
      _flushing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(flush(reason: 'lifecycle_$state'));
    }
  }

  Future<void> end() async {
    log('flush', data: {'reason': 'end'});
    await flush(reason: 'end');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    // Fire-and-forget final flush; errors swallowed.
    unawaited(flush(reason: 'dispose'));
  }

  void _ensureObserver() {
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(flushInterval, (_) {
      unawaited(flush(reason: 'timer'));
    });
  }
}
