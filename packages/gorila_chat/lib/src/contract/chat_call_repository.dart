/// WebRTC call HTTP surface (paths differ per app; UI is shared).
abstract class ChatCallRepository {
  Future<List<Map<String, dynamic>>> iceServers(int threadId);

  Future<Map<String, dynamic>> startCall(int threadId);

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
