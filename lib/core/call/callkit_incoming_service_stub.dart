typedef CallKitAcceptedHandler = Future<void> Function(Map<String, dynamic> extra, int callId);
typedef CallKitEndedHandler = Future<void> Function(int callId);

/// Web/desktop stub — CallKit доступен только на Android/iOS.
abstract final class CallKitIncomingService {
  CallKitIncomingService._();

  static CallKitAcceptedHandler? onAccepted;
  static CallKitEndedHandler? onEnded;

  static bool get isSupported => false;

  static String callUuid(int callId) => 'familychat_call_$callId';

  static int? callIdFromUuid(String? uuid) {
    if (uuid == null || uuid.isEmpty) return null;
    const prefix = 'familychat_call_';
    if (!uuid.startsWith(prefix)) return int.tryParse(uuid);
    return int.tryParse(uuid.substring(prefix.length));
  }

  static Future<void> initialize() async {}

  static Future<void> reconcileActiveCalls() async {}

  static Future<void> showIncomingCall({
    required int callId,
    required int threadId,
    required int callerUserId,
    required String callerName,
    bool isVideo = false,
    String? avatarUrl,
  }) async {}

  static Future<void> showIncomingFromPushData(Map<String, dynamic> data) async {}

  static Future<void> endCall(int callId) async {}

  static Future<void> endAllCalls() async {}
}
