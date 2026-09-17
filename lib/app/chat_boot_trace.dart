import 'dart:developer' as developer;

/// Boot / splash diagnostics. Filter: `ChatBoot`.
abstract final class ChatBootTrace {
  static const logName = 'ChatBoot';

  static void log(
    String phase, {
    String? detail,
    Map<String, Object?> extra = const {},
  }) {
    final parts = <String>['[$logName]', 'phase=$phase'];
    if (detail != null && detail.isNotEmpty) parts.add(detail);
    for (final e in extra.entries) {
      parts.add('${e.key}=${e.value}');
    }
    final line = parts.join(' ');
    developer.log(line, name: logName);
    // ignore: avoid_print — always-on for device Console / Xcode
    print(line);
  }
}
