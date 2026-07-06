import 'dart:html' as html;

bool get isIosBrowser {
  final ua = html.window.navigator.userAgent.toLowerCase();
  return ua.contains('iphone') ||
      ua.contains('ipad') ||
      ua.contains('ipod');
}

bool get isStandalonePwa {
  return html.window.matchMedia('(display-mode: standalone)').matches;
}

bool get webNotificationsSupported {
  try {
    return html.Notification.supported;
  } catch (_) {
    return false;
  }
}

String get webNotificationPermission {
  if (!webNotificationsSupported) return 'unsupported';
  return html.Notification.permission ?? 'default';
}

Future<String> requestWebNotificationPermission() async {
  if (!webNotificationsSupported) return 'unsupported';

  final current = html.Notification.permission;
  if (current == 'granted' || current == 'denied') {
    return _normalizePermission(current) ?? 'default';
  }

  try {
    final result = await html.Notification.requestPermission()
        .timeout(const Duration(seconds: 30));
    return _normalizePermission(result) ??
        _normalizePermission(html.Notification.permission) ??
        'default';
  } catch (_) {
    return _normalizePermission(html.Notification.permission) ?? 'default';
  }
}

String? _normalizePermission(String? value) {
  if (value == null || value.isEmpty) return null;
  return value;
}
