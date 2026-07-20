import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Вернуть приложение на передний план после OAuth (Custom Tab может остаться поверх).
Future<void> bringAppToForeground() async {
  if (kIsWeb) return;
  try {
    await const MethodChannel('com.familychat/lifecycle')
        .invokeMethod<void>('bringToForeground');
  } catch (_) {}
}
