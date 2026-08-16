/// WebRTC call HTTP surface (paths differ per app; UI is shared).
abstract class ChatCallRepository {
  Future<List<Map<String, dynamic>>> iceServers(int threadId);

  /// Start an audio call. Kept positional-only so TeamCoach adapters stay valid.
  Future<Map<String, dynamic>> startCall(int threadId);

  /// Optional video entry-point. Default ignores [isVideo] and calls [startCall].
  /// Family / video-capable apps override this; TeamCoach can leave the default.
  Future<Map<String, dynamic>> startCallWithOptions(
    int threadId, {
    bool isVideo = false,
  }) =>
      startCall(threadId);

  Future<Map<String, dynamic>> callAction(int callId, String action);

  Future<void> sendSignal(
    int callId, {
    required String signalType,
    required Map<String, dynamic> payload,
  });

  Future<List<Map<String, dynamic>>> listSignals(
    int callId, {
    int afterId = 0,
  });
}
