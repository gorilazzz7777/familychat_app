import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'appearance_prefs.dart';

/// Типографика текста сообщений — как в официальном Telegram Android.
///
/// TG: `Theme.chat_msgTextPaint` = system [Typeface.DEFAULT] at
/// `SharedConfig.fontSize` (default 16). Bold → Roboto Medium (w500);
/// code → Roboto Mono. No Material letter-spacing.
abstract final class ChatTextStyles {
  static const double messageFontSize =
      AppearanceFontScaleController.defaultFontSize * 1.0;

  /// Regular message / caption body (matches TG message paint).
  static TextStyle messageBody({required Color color}) {
    return TextStyle(
      fontFamily: _platformMessageFamily,
      fontSize: messageFontSize,
      fontWeight: FontWeight.w400,
      // TG TextPaint has no extra tracking; M3 bodyMedium uses 0.25.
      letterSpacing: 0,
      // null = font metrics (TG StaticLayout spacing multiplier 1.0).
      // Explicit M3 height 1.43 made bubbles look airier than Telegram.
      color: color,
    );
  }

  /// Bold / mention emphasis — TG uses medium (500), not w600/w700.
  static TextStyle messageEmphasis({required Color color}) {
    return messageBody(color: color).copyWith(fontWeight: FontWeight.w500);
  }

  static TextStyle messageLink({required Color color}) {
    return messageBody(color: color).copyWith(
      decoration: TextDecoration.none,
    );
  }

  /// Android: `sans-serif` → device UI font (One UI Sans on Samsung, Roboto
  /// on Pixel) — same as Telegram's Typeface.DEFAULT.
  /// Other platforms: leave null so Flutter/platform default applies (SF on iOS).
  static String? get _platformMessageFamily {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'sans-serif';
      default:
        return null;
    }
  }
}
