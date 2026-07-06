bool get isIosBrowser => false;

bool get isStandalonePwa => false;

bool get webNotificationsSupported => false;

String get webNotificationPermission => 'unsupported';

Future<String> requestWebNotificationPermission() async => 'unsupported';
