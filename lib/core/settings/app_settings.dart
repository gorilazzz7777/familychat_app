import 'package:flutter/foundation.dart';

@immutable
class QuietPeriod {
  const QuietPeriod({required this.start, required this.end});

  final String start;
  final String end;

  String get label => '$start — $end';

  factory QuietPeriod.fromJson(Map<String, dynamic> json) {
    return QuietPeriod(
      start: json['start']?.toString() ?? '',
      end: json['end']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'start': start, 'end': end};

  @override
  bool operator ==(Object other) =>
      other is QuietPeriod && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

@immutable
class FamilyChatAppSettings {
  const FamilyChatAppSettings({
    this.pushEnabled = true,
    this.pushMessages = true,
    this.pushCalls = true,
    this.pushCalendar = true,
    this.quietPeriods = const [],
    this.utcOffsetMinutes,
    this.canQuietHours = false,
    this.menuFeed = true,
    this.menuFamily = true,
    this.menuGallery = true,
    this.menuCalendar = true,
  });

  final bool pushEnabled;
  final bool pushMessages;
  final bool pushCalls;
  final bool pushCalendar;
  final List<QuietPeriod> quietPeriods;
  final int? utcOffsetMinutes;
  final bool canQuietHours;
  final bool menuFeed;
  final bool menuFamily;
  final bool menuGallery;
  final bool menuCalendar;

  FamilyChatAppSettings copyWith({
    bool? pushEnabled,
    bool? pushMessages,
    bool? pushCalls,
    bool? pushCalendar,
    List<QuietPeriod>? quietPeriods,
    int? utcOffsetMinutes,
    bool? canQuietHours,
    bool? menuFeed,
    bool? menuFamily,
    bool? menuGallery,
    bool? menuCalendar,
  }) {
    return FamilyChatAppSettings(
      pushEnabled: pushEnabled ?? this.pushEnabled,
      pushMessages: pushMessages ?? this.pushMessages,
      pushCalls: pushCalls ?? this.pushCalls,
      pushCalendar: pushCalendar ?? this.pushCalendar,
      quietPeriods: quietPeriods ?? this.quietPeriods,
      utcOffsetMinutes: utcOffsetMinutes ?? this.utcOffsetMinutes,
      canQuietHours: canQuietHours ?? this.canQuietHours,
      menuFeed: menuFeed ?? this.menuFeed,
      menuFamily: menuFamily ?? this.menuFamily,
      menuGallery: menuGallery ?? this.menuGallery,
      menuCalendar: menuCalendar ?? this.menuCalendar,
    );
  }

  factory FamilyChatAppSettings.fromJson(Map<String, dynamic> json) {
    final rawPeriods = json['quietPeriods'] ?? json['quiet_periods'];
    final periods = <QuietPeriod>[];
    if (rawPeriods is List) {
      for (final item in rawPeriods) {
        if (item is Map) {
          final period = QuietPeriod.fromJson(Map<String, dynamic>.from(item));
          if (period.start.isNotEmpty &&
              period.end.isNotEmpty &&
              period.start != period.end) {
            periods.add(period);
          }
        }
      }
    }
    return FamilyChatAppSettings(
      pushEnabled: _bool(json, 'pushEnabled', 'push_enabled', true),
      pushMessages: _bool(json, 'pushMessages', 'push_messages', true),
      pushCalls: _bool(json, 'pushCalls', 'push_calls', true),
      pushCalendar: _bool(json, 'pushCalendar', 'push_calendar', true),
      quietPeriods: periods,
      utcOffsetMinutes: _int(json['utcOffsetMinutes'] ?? json['utc_offset_minutes']),
      canQuietHours:
          json['canQuietHours'] == true || json['can_quiet_hours'] == true,
      menuFeed: _bool(json, 'menuFeed', 'menu_feed', true),
      menuFamily: _bool(json, 'menuFamily', 'menu_family', true),
      menuGallery: _bool(json, 'menuGallery', 'menu_gallery', true),
      menuCalendar: _bool(json, 'menuCalendar', 'menu_calendar', true),
    );
  }

  Map<String, dynamic> toPatchJson() {
    return {
      'pushEnabled': pushEnabled,
      'pushMessages': pushMessages,
      'pushCalls': pushCalls,
      'pushCalendar': pushCalendar,
      if (canQuietHours)
        'quietPeriods': quietPeriods.map((e) => e.toJson()).toList(),
      'utcOffsetMinutes':
          utcOffsetMinutes ?? DateTime.now().timeZoneOffset.inMinutes,
      'menuFeed': menuFeed,
      'menuFamily': menuFamily,
      'menuGallery': menuGallery,
      'menuCalendar': menuCalendar,
    };
  }

  Map<String, dynamic> toCacheJson() => {
        ...toPatchJson(),
        'canQuietHours': canQuietHours,
      };

  static bool _bool(
    Map<String, dynamic> json,
    String camel,
    String snake,
    bool fallback,
  ) {
    if (json[camel] == true || json[snake] == true) return true;
    if (json[camel] == false || json[snake] == false) return false;
    return fallback;
  }

  static int? _int(Object? raw) {
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }
}
