import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/local_db/chat_local_store.dart';

/// Folder-level notification mute flag (FC custom / TG folders).
///
/// Client-owned: applies to current members and to members added later.
class HubFolderMuteState {
  const HubFolderMuteState({
    required this.mode,
    this.mutedUntilMs,
    this.quietStart,
    this.quietEnd,
    this.utcOffsetMinutes,
  });

  /// `off` | `1h` | `2h` | `6h` | `24h` | `forever` | `quiet`
  final String mode;
  final int? mutedUntilMs;
  final String? quietStart;
  final String? quietEnd;
  final int? utcOffsetMinutes;

  bool get isActive {
    if (mode == 'off' || mode.isEmpty) return false;
    if (mode == 'quiet') {
      return (quietStart?.isNotEmpty ?? false) &&
          (quietEnd?.isNotEmpty ?? false);
    }
    if (mode == 'forever') return true;
    final until = mutedUntilMs;
    if (until == null) return true;
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  Map<String, dynamic> toJson() => {
        'mode': mode,
        if (mutedUntilMs != null) 'muted_until_ms': mutedUntilMs,
        if (quietStart != null) 'quiet_start': quietStart,
        if (quietEnd != null) 'quiet_end': quietEnd,
        if (utcOffsetMinutes != null) 'utc_offset_minutes': utcOffsetMinutes,
      };

  factory HubFolderMuteState.fromJson(Map<String, dynamic> json) {
    return HubFolderMuteState(
      mode: json['mode']?.toString() ?? 'off',
      mutedUntilMs: (json['muted_until_ms'] as num?)?.toInt(),
      quietStart: json['quiet_start']?.toString(),
      quietEnd: json['quiet_end']?.toString(),
      utcOffsetMinutes: (json['utc_offset_minutes'] as num?)?.toInt(),
    );
  }

  static int? mutedUntilForMode(String mode) {
    final d = switch (mode) {
      '1h' => const Duration(hours: 1),
      '2h' => const Duration(hours: 2),
      '6h' => const Duration(hours: 6),
      '24h' => const Duration(hours: 24),
      _ => null,
    };
    if (d == null) return null;
    return DateTime.now().add(d).millisecondsSinceEpoch;
  }

  /// Seconds for TDLib `mute_for` (0 = unmute).
  static int muteForSeconds(String mode, {int? mutedUntilMs}) {
    if (mode == 'off') return 0;
    if (mode == 'forever' || mode == 'quiet') {
      return 366 * 24 * 3600;
    }
    final until = mutedUntilMs ?? mutedUntilForMode(mode);
    if (until == null) return 366 * 24 * 3600;
    final sec = ((until - DateTime.now().millisecondsSinceEpoch) / 1000)
        .ceil();
    return sec.clamp(1, 366 * 24 * 3600);
  }
}

/// Persist folder mute flags in SQLite meta (`hub_folder_mute_v1`).
abstract final class HubFolderMuteStore {
  static const _metaKey = 'hub_folder_mute_v1';
  static Map<String, HubFolderMuteState>? _cache;

  static Map<String, HubFolderMuteState> get snapshot =>
      Map<String, HubFolderMuteState>.from(_cache ?? const {});

  static HubFolderMuteState? get(String folderKey) {
    final s = _cache?[folderKey];
    if (s == null) return null;
    if (!s.isActive && s.mode != 'quiet' && s.mode != 'off') {
      return HubFolderMuteState(mode: 'off');
    }
    return s;
  }

  static bool isActive(String folderKey) => get(folderKey)?.isActive ?? false;

  static Future<void> ensureLoaded() async {
    if (_cache != null) return;
    await load();
  }

  static Future<void> load() async {
    if (kIsWeb || !ChatLocalStore.isSupported) {
      _cache = {};
      return;
    }
    try {
      await ChatLocalStore.instance.ensureOpen();
      final raw = await ChatLocalStore.instance.metaGet(_metaKey);
      if (raw == null || raw.isEmpty) {
        _cache = {};
        return;
      }
      final decoded = jsonDecode(raw);
      final map = <String, HubFolderMuteState>{};
      if (decoded is Map) {
        for (final e in decoded.entries) {
          final key = e.key.toString();
          final v = e.value;
          if (v is! Map) continue;
          map[key] = HubFolderMuteState.fromJson(
            Map<String, dynamic>.from(v),
          );
        }
      }
      _cache = map;
    } catch (e) {
      debugPrint('[folder-mute] load failed: $e');
      _cache = {};
    }
  }

  static Future<void> set(String folderKey, HubFolderMuteState state) async {
    await ensureLoaded();
    final next = Map<String, HubFolderMuteState>.from(_cache ?? {});
    if (state.mode == 'off') {
      next.remove(folderKey);
    } else {
      next[folderKey] = state;
    }
    _cache = next;
    await _persist();
  }

  static Future<void> clear(String folderKey) async {
    await set(folderKey, const HubFolderMuteState(mode: 'off'));
  }

  static Future<void> _persist() async {
    if (kIsWeb || !ChatLocalStore.isSupported) return;
    try {
      final encoded = <String, dynamic>{
        for (final e in (_cache ?? {}).entries) e.key: e.value.toJson(),
      };
      await ChatLocalStore.instance.ensureOpen();
      await ChatLocalStore.instance.metaSet(_metaKey, jsonEncode(encoded));
    } catch (e) {
      debugPrint('[folder-mute] persist failed: $e');
    }
  }
}
