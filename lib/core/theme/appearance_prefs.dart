import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fontScaleKey = 'familychat_appearance_font_scale_v1';
const _wallpaperKey = 'familychat_appearance_chat_wallpaper_v2';

/// `null` = системный масштаб шрифта.
final appearanceFontScaleProvider =
    StateNotifierProvider<AppearanceFontScaleController, double?>((ref) {
  return AppearanceFontScaleController();
});

final chatWallpaperIdProvider =
    StateNotifierProvider<ChatWallpaperController, String>((ref) {
  return ChatWallpaperController();
});

class AppearanceFontScaleController extends StateNotifier<double?> {
  AppearanceFontScaleController() : super(null) {
    unawaited(_load());
  }

  /// Базовый размер текста сообщений (как в Telegram).
  static const minFontSize = 12;
  static const maxFontSize = 22;
  static const defaultFontSize = 16;

  /// `null` = системный масштаб (ползунок на 16).
  static int fontSizeFromScale(double? scale) {
    if (scale == null) return defaultFontSize;
    return (scale * defaultFontSize).round().clamp(minFontSize, maxFontSize);
  }

  static double? scaleFromFontSize(int fontSize) {
    if (fontSize == defaultFontSize) return null;
    return fontSize / defaultFontSize;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_fontScaleKey)) return;
      final raw = prefs.getDouble(_fontScaleKey);
      if (raw == null) {
        state = null;
        return;
      }
      state = raw;
    } catch (_) {}
  }

  Future<void> setScale(double? scale) async {
    state = scale;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (scale == null) {
        await prefs.remove(_fontScaleKey);
      } else {
        await prefs.setDouble(_fontScaleKey, scale);
      }
    } catch (_) {}
  }
}

class ChatWallpaperController extends StateNotifier<String> {
  ChatWallpaperController() : super(ChatWallpaperCatalog.defaultId) {
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_wallpaperKey)?.trim() ?? '';
      if (id.isEmpty) return;
      if (ChatWallpaperCatalog.byId(id) == null) return;
      state = id;
    } catch (_) {}
  }

  Future<void> setId(String id) async {
    if (ChatWallpaperCatalog.byId(id) == null) return;
    state = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_wallpaperKey, id);
    } catch (_) {}
  }
}

class ChatWallpaperSpec {
  const ChatWallpaperSpec({
    required this.id,
    required this.label,
    required this.assetPath,
  });

  final String id;
  final String label;
  final String assetPath;
}

abstract final class ChatWallpaperCatalog {
  /// Фон 1 из папки «фоны».
  static const defaultId = 'wallpaper_1';

  static const all = <ChatWallpaperSpec>[
    ChatWallpaperSpec(
      id: 'wallpaper_1',
      label: 'Фон 1',
      assetPath: 'assets/chat/wallpapers/wallpaper_1.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_2',
      label: 'Фон 2',
      assetPath: 'assets/chat/wallpapers/wallpaper_2.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_3',
      label: 'Фон 3',
      assetPath: 'assets/chat/wallpapers/wallpaper_3.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_4',
      label: 'Фон 4',
      assetPath: 'assets/chat/wallpapers/wallpaper_4.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_5',
      label: 'Фон 5',
      assetPath: 'assets/chat/wallpapers/wallpaper_5.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_6',
      label: 'Фон 6',
      assetPath: 'assets/chat/wallpapers/wallpaper_6.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_7',
      label: 'Фон 7',
      assetPath: 'assets/chat/wallpapers/wallpaper_7.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_8',
      label: 'Фон 8',
      assetPath: 'assets/chat/wallpapers/wallpaper_8.jpg',
    ),
    ChatWallpaperSpec(
      id: 'wallpaper_9',
      label: 'Фон 9',
      assetPath: 'assets/chat/wallpapers/wallpaper_9.jpg',
    ),
  ];

  static ChatWallpaperSpec? byId(String id) {
    for (final item in all) {
      if (item.id == id) return item;
    }
    return null;
  }
}

/// Фон чата / превью оформления.
class ChatWallpaperBackdrop extends StatelessWidget {
  const ChatWallpaperBackdrop({
    super.key,
    required this.wallpaperId,
    this.child,
  });

  final String wallpaperId;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final spec =
        ChatWallpaperCatalog.byId(wallpaperId) ?? ChatWallpaperCatalog.all.first;
    final backdrop = Image.asset(
      spec.assetPath,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const SizedBox.expand(),
      ),
    );

    if (child == null) {
      return SizedBox.expand(child: backdrop);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: backdrop),
        Positioned.fill(child: child!),
      ],
    );
  }
}
