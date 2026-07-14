import 'dart:html' as html;

String get _ua => html.window.navigator.userAgent.toLowerCase();

bool get isIosBrowser {
  final ua = _ua;
  return ua.contains('iphone') ||
      ua.contains('ipad') ||
      ua.contains('ipod');
}

/// Safari на iPhone/iPad (не Chrome/Firefox/Edge поверх WebKit).
bool get isSafariBrowser {
  final ua = _ua;
  if (!ua.contains('safari')) return false;
  // Chrome/Firefox/Edge на iOS тоже содержат «Safari» в UA.
  return !ua.contains('crios') &&
      !ua.contains('fxios') &&
      !ua.contains('edgios') &&
      !ua.contains('chromium');
}

bool get isStandalonePwa {
  final window = html.window;
  return window.matchMedia('(display-mode: standalone)').matches ||
      window.matchMedia('(display-mode: fullscreen)').matches ||
      window.matchMedia('(display-mode: minimal-ui)').matches;
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
