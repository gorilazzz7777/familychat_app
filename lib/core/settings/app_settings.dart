import 'package:flutter/foundation.dart';

import 'media_storage_options.dart';
import 'screen_timeout.dart';

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
    this.pushFeed = true,
    this.quietPeriods = const [],
    this.utcOffsetMinutes,
    this.canQuietHours = false,
    this.menuFeed = true,
    this.menuFamily = true,
    this.menuGallery = true,
    this.menuCalendar = true,
    this.menuOrder = defaultMenuOrder,
    this.screenTimeout = ScreenTimeoutOption.system,
    this.autoSaveIncomingToGallery = false,
    this.mediaCacheStale = MediaCacheStaleOption.thirtyDays,
    this.mediaCacheSize = MediaCacheSizeOption.gb2,
    this.chatAutoDownloadPhotosWifi = true,
    this.chatAutoDownloadPhotosMobile = true,
    this.chatAutoDownloadVideosWifi = true,
    this.chatAutoDownloadVideosMobile = true,
    this.chatAutoDownloadFilesWifi = true,
    this.chatAutoDownloadFilesMobile = true,
    this.chatAutoDownloadVoiceWifi = true,
    this.chatAutoDownloadVoiceMobile = true,
  });

  static const defaultMenuOrder = [
    'chat',
    'feed',
    'family',
    'gallery',
    'calendar',
  ];

  final bool pushEnabled;
  final bool pushMessages;
  final bool pushCalls;
  final bool pushCalendar;
  final bool pushFeed;
  final List<QuietPeriod> quietPeriods;
  final int? utcOffsetMinutes;
  final bool canQuietHours;
  final bool menuFeed;
  final bool menuFamily;
  final bool menuGallery;
  final bool menuCalendar;
  final List<String> menuOrder;
  final ScreenTimeoutOption screenTimeout;
  final bool autoSaveIncomingToGallery;
  final MediaCacheStaleOption mediaCacheStale;
  final MediaCacheSizeOption mediaCacheSize;
  final bool chatAutoDownloadPhotosWifi;
  final bool chatAutoDownloadPhotosMobile;
  final bool chatAutoDownloadVideosWifi;
  final bool chatAutoDownloadVideosMobile;
  final bool chatAutoDownloadFilesWifi;
  final bool chatAutoDownloadFilesMobile;
  final bool chatAutoDownloadVoiceWifi;
  final bool chatAutoDownloadVoiceMobile;

  FamilyChatAppSettings copyWith({
    bool? pushEnabled,
    bool? pushMessages,
    bool? pushCalls,
    bool? pushCalendar,
    bool? pushFeed,
    List<QuietPeriod>? quietPeriods,
    int? utcOffsetMinutes,
    bool? canQuietHours,
    bool? menuFeed,
    bool? menuFamily,
    bool? menuGallery,
    bool? menuCalendar,
    List<String>? menuOrder,
    ScreenTimeoutOption? screenTimeout,
    bool? autoSaveIncomingToGallery,
    MediaCacheStaleOption? mediaCacheStale,
    MediaCacheSizeOption? mediaCacheSize,
    bool? chatAutoDownloadPhotosWifi,
    bool? chatAutoDownloadPhotosMobile,
    bool? chatAutoDownloadVideosWifi,
    bool? chatAutoDownloadVideosMobile,
    bool? chatAutoDownloadFilesWifi,
    bool? chatAutoDownloadFilesMobile,
    bool? chatAutoDownloadVoiceWifi,
    bool? chatAutoDownloadVoiceMobile,
  }) {
    return FamilyChatAppSettings(
      pushEnabled: pushEnabled ?? this.pushEnabled,
      pushMessages: pushMessages ?? this.pushMessages,
      pushCalls: pushCalls ?? this.pushCalls,
      pushCalendar: pushCalendar ?? this.pushCalendar,
      pushFeed: pushFeed ?? this.pushFeed,
      quietPeriods: quietPeriods ?? this.quietPeriods,
      utcOffsetMinutes: utcOffsetMinutes ?? this.utcOffsetMinutes,
      canQuietHours: canQuietHours ?? this.canQuietHours,
      menuFeed: menuFeed ?? this.menuFeed,
      menuFamily: menuFamily ?? this.menuFamily,
      menuGallery: menuGallery ?? this.menuGallery,
      menuCalendar: menuCalendar ?? this.menuCalendar,
      menuOrder: menuOrder ?? this.menuOrder,
      screenTimeout: screenTimeout ?? this.screenTimeout,
      autoSaveIncomingToGallery:
          autoSaveIncomingToGallery ?? this.autoSaveIncomingToGallery,
      mediaCacheStale: mediaCacheStale ?? this.mediaCacheStale,
      mediaCacheSize: mediaCacheSize ?? this.mediaCacheSize,
      chatAutoDownloadPhotosWifi:
          chatAutoDownloadPhotosWifi ?? this.chatAutoDownloadPhotosWifi,
      chatAutoDownloadPhotosMobile:
          chatAutoDownloadPhotosMobile ?? this.chatAutoDownloadPhotosMobile,
      chatAutoDownloadVideosWifi:
          chatAutoDownloadVideosWifi ?? this.chatAutoDownloadVideosWifi,
      chatAutoDownloadVideosMobile:
          chatAutoDownloadVideosMobile ?? this.chatAutoDownloadVideosMobile,
      chatAutoDownloadFilesWifi:
          chatAutoDownloadFilesWifi ?? this.chatAutoDownloadFilesWifi,
      chatAutoDownloadFilesMobile:
          chatAutoDownloadFilesMobile ?? this.chatAutoDownloadFilesMobile,
      chatAutoDownloadVoiceWifi:
          chatAutoDownloadVoiceWifi ?? this.chatAutoDownloadVoiceWifi,
      chatAutoDownloadVoiceMobile:
          chatAutoDownloadVoiceMobile ?? this.chatAutoDownloadVoiceMobile,
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
      pushFeed: _bool(json, 'pushFeed', 'push_feed', true),
      quietPeriods: periods,
      utcOffsetMinutes: _int(json['utcOffsetMinutes'] ?? json['utc_offset_minutes']),
      canQuietHours:
          json['canQuietHours'] == true || json['can_quiet_hours'] == true,
      menuFeed: _bool(json, 'menuFeed', 'menu_feed', true),
      menuFamily: _bool(json, 'menuFamily', 'menu_family', true),
      menuGallery: _bool(json, 'menuGallery', 'menu_gallery', true),
      menuCalendar: _bool(json, 'menuCalendar', 'menu_calendar', true),
      menuOrder: _stringList(json['menuOrder'] ?? json['menu_order']),
      screenTimeout: ScreenTimeoutOptionX.fromStorage(
        json['screenTimeout'] ?? json['screen_timeout'],
      ),
      autoSaveIncomingToGallery: _bool(
        json,
        'autoSaveIncomingToGallery',
        'auto_save_incoming_to_gallery',
        false,
      ),
      mediaCacheStale: MediaCacheStaleOptionX.fromStorage(
        json['mediaCacheStale'] ?? json['media_cache_stale'],
      ),
      mediaCacheSize: MediaCacheSizeOptionX.fromStorage(
        json['mediaCacheSize'] ?? json['media_cache_size'],
      ),
      chatAutoDownloadPhotosWifi: _bool(
        json,
        'chatAutoDownloadPhotosWifi',
        'chat_auto_download_photos_wifi',
        true,
      ),
      chatAutoDownloadPhotosMobile: _bool(
        json,
        'chatAutoDownloadPhotosMobile',
        'chat_auto_download_photos_mobile',
        true,
      ),
      chatAutoDownloadVideosWifi: _bool(
        json,
        'chatAutoDownloadVideosWifi',
        'chat_auto_download_videos_wifi',
        true,
      ),
      chatAutoDownloadVideosMobile: _bool(
        json,
        'chatAutoDownloadVideosMobile',
        'chat_auto_download_videos_mobile',
        true,
      ),
      chatAutoDownloadFilesWifi: _bool(
        json,
        'chatAutoDownloadFilesWifi',
        'chat_auto_download_files_wifi',
        true,
      ),
      chatAutoDownloadFilesMobile: _bool(
        json,
        'chatAutoDownloadFilesMobile',
        'chat_auto_download_files_mobile',
        true,
      ),
      chatAutoDownloadVoiceWifi: _bool(
        json,
        'chatAutoDownloadVoiceWifi',
        'chat_auto_download_voice_wifi',
        true,
      ),
      chatAutoDownloadVoiceMobile: _bool(
        json,
        'chatAutoDownloadVoiceMobile',
        'chat_auto_download_voice_mobile',
        true,
      ),
    );
  }

  Map<String, dynamic> toPatchJson() {
    return {
      'pushEnabled': pushEnabled,
      'pushMessages': pushMessages,
      'pushCalls': pushCalls,
      'pushCalendar': pushCalendar,
      'pushFeed': pushFeed,
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
        'screenTimeout': screenTimeout.storageKey,
        'menuOrder': menuOrder,
        'autoSaveIncomingToGallery': autoSaveIncomingToGallery,
        'mediaCacheStale': mediaCacheStale.storageKey,
        'mediaCacheSize': mediaCacheSize.storageKey,
        'chatAutoDownloadPhotosWifi': chatAutoDownloadPhotosWifi,
        'chatAutoDownloadPhotosMobile': chatAutoDownloadPhotosMobile,
        'chatAutoDownloadVideosWifi': chatAutoDownloadVideosWifi,
        'chatAutoDownloadVideosMobile': chatAutoDownloadVideosMobile,
        'chatAutoDownloadFilesWifi': chatAutoDownloadFilesWifi,
        'chatAutoDownloadFilesMobile': chatAutoDownloadFilesMobile,
        'chatAutoDownloadVoiceWifi': chatAutoDownloadVoiceWifi,
        'chatAutoDownloadVoiceMobile': chatAutoDownloadVoiceMobile,
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

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return defaultMenuOrder;
    final keys = <String>[];
    for (final item in raw) {
      final key = item.toString().trim();
      if (key.isEmpty || keys.contains(key)) continue;
      keys.add(key);
    }
    return keys.isEmpty ? defaultMenuOrder : keys;
  }
}
