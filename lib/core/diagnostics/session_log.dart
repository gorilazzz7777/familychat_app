import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Debug-only diagnostic event store for post-hoc AI analysis (adb pull).
///
/// **When:** [kDebugMode] only — always on in debug builds (no-op in release).
/// **Where:** `<app_documents>/fc_diag/tg_YYYYMMDD_HH.jsonl` (hourly JSONL).
/// **Retention:** files older than [retention] are deleted (default 48h).
///
/// Covers app-wide state (lifecycle, network, nav, bootstrap, FC, TG, errors)
/// via [AppSessionDiagnostics] plus Telegram chat/media categories.
///
/// Pull example (Android):
/// ```
/// adb shell run-as com.familychat.familychat_app \
///   ls app_flutter/fc_diag
/// adb exec-out run-as com.familychat.familychat_app \
///   cat app_flutter/fc_diag/tg_YYYYMMDD_HH.jsonl > tg_diag.jsonl
/// ```
/// If `run-as` fails (release/non-debuggable), copy via:
/// ```
/// adb shell "run-as com.familychat.familychat_app cp -r app_flutter/fc_diag /sdcard/Download/fc_diag"
/// adb pull /sdcard/Download/fc_diag
/// ```
///
/// Line format (JSONL) — fields for AI, not humans:
/// `{"ts":"ISO-UTC","cat":"app.life","evt":"change","from":"paused","to":"resumed",…}`
class SessionLog {
  SessionLog._();
  static final SessionLog instance = SessionLog._();

  static const retention = Duration(hours: 48);
  static const _dirName = 'fc_diag';
  static const _maxQueued = 2000;

  static bool get enabled => kDebugMode;

  final Queue<String> _queue = Queue<String>();
  bool _pumping = false;
  bool _ready = false;
  Directory? _dir;
  String? _currentFileName;
  IOSink? _sink;
  DateTime? _lastPruneAt;
  Future<void>? _init;
  final Map<String, DateTime> _throttleAt = {};

  /// Absolute directory path once initialized (for debugPrint / agent).
  String? get directoryPath => _dir?.path;

  Future<void> ensureStarted() {
    if (!enabled) return Future<void>.value();
    return _init ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      _dir = Directory(p.join(docs.path, _dirName));
      await _dir!.create(recursive: true);
      _ready = true;
      await _pruneOldFiles();
      debugPrint('[session-log] dir=${_dir!.path} retention=${retention.inHours}h');
      event('diag', 'boot', {
        'dir': _dir!.path,
        'retentionHours': retention.inHours,
      });
      _pump();
    } catch (e) {
      debugPrint('[session-log] init failed: $e');
      _ready = false;
    }
  }

  /// Structured event. [fields] null values are dropped.
  void event(String cat, String evt, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    final map = <String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'cat': cat,
      'evt': evt,
    };
    for (final e in fields.entries) {
      if (e.value != null) map[e.key] = e.value;
    }
    _enqueue(jsonEncode(map));
  }

  /// Like [event], but drops repeats of the same [key] within [minInterval].
  void throttled(
    String cat,
    String evt, {
    required String key,
    Duration minInterval = const Duration(seconds: 2),
    Map<String, Object?> fields = const {},
  }) {
    if (!enabled) return;
    final now = DateTime.now();
    final last = _throttleAt[key];
    if (last != null && now.difference(last) < minInterval) return;
    _throttleAt[key] = now;
    event(cat, evt, fields);
  }

  /// Free-form trace line already curated (e.g. tdlib-media). Avoid dumping
  /// raw high-frequency progress here.
  void trace(String cat, String message) {
    if (!enabled) return;
    event(cat, 'trace', {'msg': message});
  }

  /// Truncated message body for AI context (not for humans).
  static String? textPreview(String? text, {int max = 120}) {
    if (text == null) return null;
    final s = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return null;
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }

  void _enqueue(String line) {
    unawaited(ensureStarted());
    if (_queue.length >= _maxQueued) {
      // Prefer recent signal when flooded.
      _queue.removeFirst();
    }
    _queue.add(line);
    _pump();
  }

  void _pump() {
    if (!enabled || _pumping) return;
    _pumping = true;
    scheduleMicrotask(() async {
      try {
        while (_queue.isNotEmpty) {
          if (!_ready) {
            await ensureStarted();
            if (!_ready) break;
          }
          await _rotateSinkIfNeeded();
          final sink = _sink;
          if (sink == null) break;
          final batch = StringBuffer();
          var n = 0;
          while (_queue.isNotEmpty && n < 64) {
            batch.writeln(_queue.removeFirst());
            n++;
          }
          sink.write(batch.toString());
          // Cheap durability without fsync every line.
          if (n >= 16) await sink.flush();
        }
        final last = _lastPruneAt;
        if (last == null ||
            DateTime.now().difference(last) > const Duration(minutes: 30)) {
          await _pruneOldFiles();
        }
      } catch (e) {
        debugPrint('[session-log] write failed: $e');
      } finally {
        _pumping = false;
        if (_queue.isNotEmpty) _pump();
      }
    });
  }

  Future<void> _rotateSinkIfNeeded() async {
    final dir = _dir;
    if (dir == null) return;
    final name = _fileNameFor(DateTime.now().toUtc());
    if (_currentFileName == name && _sink != null) return;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _currentFileName = name;
    final file = File(p.join(dir.path, name));
    _sink = file.openWrite(mode: FileMode.append);
  }

  static String _fileNameFor(DateTime utc) {
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    final h = utc.hour.toString().padLeft(2, '0');
    return 'tg_${y}${m}${d}_${h}.jsonl';
  }

  Future<void> _pruneOldFiles() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return;
    _lastPruneAt = DateTime.now();
    final cutoff = DateTime.now().toUtc().subtract(retention);
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        if (!base.startsWith('tg_') || !base.endsWith('.jsonl')) continue;
        final stamp = _parseFileStamp(base);
        if (stamp != null && stamp.isBefore(cutoff)) {
          await entity.delete();
          continue;
        }
        // Fallback: mtime if name unparsable.
        if (stamp == null) {
          final stat = await entity.stat();
          if (stat.modified.toUtc().isBefore(cutoff)) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('[session-log] prune failed: $e');
    }
  }

  /// `tg_YYYYMMDD_HH.jsonl` → UTC DateTime at hour start.
  static DateTime? _parseFileStamp(String name) {
    final re = RegExp(r'^tg_(\d{4})(\d{2})(\d{2})_(\d{2})\.jsonl$');
    final m = re.firstMatch(name);
    if (m == null) return null;
    return DateTime.utc(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
    );
  }

  Future<void> flush() async {
    if (!enabled) return;
    while (_queue.isNotEmpty || _pumping) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _sink?.flush();
  }
}
